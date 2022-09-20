{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE ImportQualifiedPost   #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
-- Options
{-# OPTIONS_GHC -fno-strictness               #-}
{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas   #-}
{-# OPTIONS_GHC -fobject-code                 #-}
{-# OPTIONS_GHC -fno-specialise               #-}
{-# OPTIONS_GHC -fexpose-all-unfoldings       #-}
module VotingContract
  ( votingContractScript
  , votingContractScriptShortBs
  , CustomDatumType
  ) where
import qualified PlutusTx
import           PlutusTx.Prelude
import           Cardano.Api.Shelley            ( PlutusScript (..), PlutusScriptV2 )
import           Codec.Serialise                ( serialise )
import qualified Data.ByteString.Lazy           as LBS
import qualified Data.ByteString.Short          as SBS
import qualified Plutus.V1.Ledger.Scripts       as Scripts
import qualified Plutus.V1.Ledger.Value         as Value
import qualified Plutus.V2.Ledger.Contexts      as ContextsV2
import qualified Plutus.V2.Ledger.Api           as PlutusV2
import           Plutus.Script.Utils.V2.Scripts as Utils
import           CheckFuncs
{- |
  Author   : The Ancient Kraken
  Copyright: 2022
  Version  : Rev 2
-}
lockPid :: PlutusV2.CurrencySymbol
lockPid = PlutusV2.CurrencySymbol {PlutusV2.unCurrencySymbol = createBuiltinByteString [86, 19, 166, 8, 166, 59, 78, 115, 117, 70, 118, 139, 197, 129, 162, 143, 216, 217, 215, 8, 146, 203, 180, 185, 231, 117, 154, 80] }

lockTkn :: PlutusV2.TokenName
lockTkn = PlutusV2.TokenName {PlutusV2.unTokenName = createBuiltinByteString [97, 99, 116, 105, 111, 110, 95, 116, 111, 107, 101, 110] }

lockValue :: PlutusV2.Value
lockValue = Value.singleton lockPid lockTkn (1 :: Integer)

-------------------------------------------------------------------------------
-- | Create the delegation parameters data object.
-------------------------------------------------------------------------------
data DelegationType = DelegationType
    { dtPkh    :: PlutusV2.PubKeyHash
    -- ^ The did public key hash.
    , dtIouPid :: PlutusV2.CurrencySymbol
    -- ^ The dids iou policy id.
    }
PlutusTx.unstableMakeIsData ''DelegationType
-------------------------------------------------------------------------------
-- | Create the datum parameters data object.
-------------------------------------------------------------------------------
data CustomDatumType = CustomDatumType
    { cdtPid :: PlutusV2.CurrencySymbol
    -- ^ The voting token's policy id
    , cdtTkn :: PlutusV2.TokenName
    -- ^ The voting token's token name.
    , cdtAmt :: Integer
    -- ^ The voting token's threshold amount.
    }
PlutusTx.unstableMakeIsData ''CustomDatumType
-- old == new
updateThresholdAmount :: CustomDatumType -> CustomDatumType -> Bool
updateThresholdAmount a b = ( cdtPid a == cdtPid b ) &&
                            ( cdtTkn a == cdtTkn b ) &&
                            ( cdtAmt a /= cdtAmt b ) -- should this be greater than or some bound function?
-------------------------------------------------------------------------------
-- | Create the redeemer type.
-------------------------------------------------------------------------------
data CustomRedeemerType = Vote   |
                          Debug
PlutusTx.makeIsDataIndexed ''CustomRedeemerType [ ('Vote,  0)
                                                , ('Debug, 1)
                                                ]
-------------------------------------------------------------------------------
-- | mkValidator :: Datum -> Redeemer -> ScriptContext -> Bool
-------------------------------------------------------------------------------
{-# INLINABLE mkValidator #-}
mkValidator :: CustomDatumType -> CustomRedeemerType -> PlutusV2.ScriptContext -> Bool
mkValidator datum redeemer context =
  case redeemer of
    Vote -> do 
      { let a = traceIfFalse "Voting Has Failed Error"   $ checkReferenceSigners txRefInputs (Value.singleton Value.adaSymbol Value.adaToken (0 :: Integer))
      ; let b = traceIfFalse "Single Script Input Error" $ isNInputs txInputs 1 && isNOutputs contOutputs 1
      ; let c = traceIfFalse "Missing Starter NFT Error" $ Value.geq validatingValue lockValue
      ; let d = traceIfFalse "Datum Update Error"        $ isEmbeddedDatum contOutputs
      ;         traceIfFalse "Vote Endpoint Error"       $ all (==True) [a,b,c,d]
      }
    Debug -> True
   where
    info :: PlutusV2.TxInfo
    info = PlutusV2.scriptContextTxInfo context

    -- continuing ouputs
    contOutputs :: [PlutusV2.TxOut]
    contOutputs = ContextsV2.getContinuingOutputs context

    -- tx inputs
    txInputs :: [PlutusV2.TxInInfo]
    txInputs = PlutusV2.txInfoInputs  info

    -- tx inputs
    txRefInputs :: [PlutusV2.TxInInfo]
    txRefInputs = PlutusV2.txInfoReferenceInputs  info

    -- token that is being validated
    validatingValue :: PlutusV2.Value
    validatingValue =
      case ContextsV2.findOwnInput context of
        Nothing    -> traceError "No Input to Validate." -- This error should never be hit.
        Just input -> PlutusV2.txOutValue $ PlutusV2.txInInfoResolved input

    -- check if the outgoing datum has the correct form.
    isEmbeddedDatum :: [PlutusV2.TxOut] -> Bool
    isEmbeddedDatum []     = False
    isEmbeddedDatum (x:xs) =
      if PlutusV2.txOutValue x == validatingValue -- strict value continue
        then
          case PlutusV2.txOutDatum x of
            PlutusV2.NoOutputDatum       -> isEmbeddedDatum xs -- datumless
            (PlutusV2.OutputDatumHash _) -> isEmbeddedDatum xs -- embedded datum
            -- inline datum
            (PlutusV2.OutputDatum (PlutusV2.Datum d)) -> 
              case PlutusTx.fromBuiltinData d of
                Nothing     -> isEmbeddedDatum xs
                Just inline -> updateThresholdAmount datum inline
        else isEmbeddedDatum xs
        
    
    -- check if the outgoing datum has the correct form.
    checkReferenceSigners :: [PlutusV2.TxInInfo] -> PlutusV2.Value -> Bool
    checkReferenceSigners []     val = isVoteComplete (cdtPid datum) (cdtTkn datum) (cdtAmt datum) info val -- input the voting token info
    checkReferenceSigners (x:xs) val = 
      case PlutusV2.txOutDatum $ PlutusV2.txInInfoResolved x of
        PlutusV2.NoOutputDatum       -> checkReferenceSigners xs val -- datumless
        (PlutusV2.OutputDatumHash _) -> checkReferenceSigners xs val -- embedded datum
        -- inline datum
        (PlutusV2.OutputDatum (PlutusV2.Datum d)) -> 
          case PlutusTx.fromBuiltinData @DelegationType d of
            Nothing     -> checkReferenceSigners xs val
            Just inline -> 
              if ContextsV2.txSignedBy info (dtPkh inline)
              then checkReferenceSigners xs (val + (PlutusV2.txOutValue $ PlutusV2.txInInfoResolved x))
              else checkReferenceSigners xs val
        
                  
-------------------------------------------------------------------------------
-- | Now we need to compile the Validator.
-------------------------------------------------------------------------------
validator' :: PlutusV2.Validator
validator' = PlutusV2.mkValidatorScript
    $$(PlutusTx.compile [|| wrap ||])
 where
    wrap = Utils.mkUntypedValidator mkValidator
-------------------------------------------------------------------------------
-- | The code below is required for the plutus script compile.
-------------------------------------------------------------------------------
script :: Scripts.Script
script = Scripts.unValidatorScript validator'

votingContractScriptShortBs :: SBS.ShortByteString
votingContractScriptShortBs = SBS.toShort . LBS.toStrict $ serialise script

votingContractScript :: PlutusScript PlutusScriptV2
votingContractScript = PlutusScriptSerialised votingContractScriptShortBs