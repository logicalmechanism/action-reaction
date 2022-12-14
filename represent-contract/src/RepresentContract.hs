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
module RepresentContract
  ( representContractScript
  , representContractScriptShortBs
  ) where
import qualified PlutusTx
import           PlutusTx.Prelude
import           Cardano.Api.Shelley            ( PlutusScript (..), PlutusScriptV2 )
import           Codec.Serialise                ( serialise )
import qualified Data.ByteString.Lazy           as LBS
import qualified Data.ByteString.Short          as SBS
import qualified Plutus.V1.Ledger.Scripts       as Scripts
import qualified Plutus.V2.Ledger.Contexts      as ContextsV2
import qualified Plutus.V2.Ledger.Api           as PlutusV2
import qualified Plutus.V1.Ledger.Address       as Addr
import qualified Plutus.V1.Ledger.Value         as Value
import           Plutus.Script.Utils.V2.Scripts as Utils
import           CheckFuncs
{- |
  Author   : The Ancient Kraken
  Copyright: 2022
  Version  : Rev 1
-}
iouTkn :: PlutusV2.TokenName
iouTkn = PlutusV2.TokenName {PlutusV2.unTokenName = createBuiltinByteString [105, 111, 117]}

voteValidatorHash :: PlutusV2.ValidatorHash
voteValidatorHash = PlutusV2.ValidatorHash $ createBuiltinByteString [212, 194, 250, 238, 62, 72, 116, 73, 37, 67, 162, 67, 66, 1, 126, 69, 142, 67, 110, 61, 103, 201, 15, 138, 63, 136, 196, 217]

lockPid :: PlutusV2.CurrencySymbol
lockPid = PlutusV2.CurrencySymbol {PlutusV2.unCurrencySymbol = createBuiltinByteString [79, 12, 163, 101, 213, 218, 28, 33, 71, 246, 155, 113, 91, 185, 29, 191, 24, 14, 59, 209, 195, 211, 11, 183, 60, 116, 15, 207] }

lockTkn :: PlutusV2.TokenName
lockTkn = PlutusV2.TokenName {PlutusV2.unTokenName = createBuiltinByteString [97, 99, 116, 105, 111, 110, 95, 116, 111, 107, 101, 110] }

lockValue :: PlutusV2.Value
lockValue = Value.singleton lockPid lockTkn (1 :: Integer)

-------------------------------------------------------------------------------
-- | Create the voting datum parameters data object.
-------------------------------------------------------------------------------
data VoteDatumType = VoteDatumType
    { vdtPid :: PlutusV2.CurrencySymbol
    -- ^ The voting token's policy id
    , vdtTkn :: PlutusV2.TokenName
    -- ^ The voting token's token name.
    , vdtAmt :: Integer
    -- ^ The voting token's threshold amount.
    }
PlutusTx.unstableMakeIsData ''VoteDatumType
-------------------------------------------------------------------------------
-- | Create the datum parameters data object.
-------------------------------------------------------------------------------
data CustomDatumType = CustomDatumType
    { cdtPkh    :: PlutusV2.PubKeyHash
    -- ^ The representor's public key hash.
    , cdtIouPid :: PlutusV2.CurrencySymbol
    -- ^ The iou policy id.
    }
PlutusTx.unstableMakeIsData ''CustomDatumType
-- old == new
instance Eq CustomDatumType where
  {-# INLINABLE (==) #-}
  a == b = ( cdtPkh    a == cdtPkh    b ) &&
           ( cdtIouPid a == cdtIouPid b )
-------------------------------------------------------------------------------
-- | Create the redeemer parameters data object.
-------------------------------------------------------------------------------
data UpdateType = UpdateType
  { updateAmt :: Integer
  -- ^ The updater's amount to increase or decrease.
  , updaterPkh  :: PlutusV2.PubKeyHash
  -- ^ The updater's public key hash.
  , updaterSc  :: PlutusV2.PubKeyHash
  -- ^ The updater's staking credential.
  }
PlutusTx.unstableMakeIsData ''UpdateType
-------------------------------------------------------------------------------
-- | Create the redeemer type.
-------------------------------------------------------------------------------
data CustomRedeemerType = Increase UpdateType |
                          Decrease UpdateType |
                          Remove
PlutusTx.makeIsDataIndexed ''CustomRedeemerType [ ( 'Increase, 0 )
                                                , ( 'Decrease, 1 )
                                                , ( 'Remove,   2 )
                                                ]
-------------------------------------------------------------------------------
-- | mkValidator :: Datum -> Redeemer -> ScriptContext -> Bool
-------------------------------------------------------------------------------
{-# INLINABLE mkValidator #-}
mkValidator :: CustomDatumType -> CustomRedeemerType -> PlutusV2.ScriptContext -> Bool
mkValidator datum redeemer context =
  case redeemer of
    Remove -> do 
      { let a = traceIfFalse "Signing Tx Error"     $ ContextsV2.txSignedBy info (cdtPkh datum)             -- must be signed by rep
      ; let b = traceIfFalse "Voters Are Delegated" $ hasVotngTokens                                        -- can not hold any voting tokens in tx
      ; let c = traceIfFalse "Single Script Error"  $ isSingleScript txInputs && isSingleScript txRefInputs -- single input single output
      ;         traceIfFalse "Remove Error"         $ all (==True) [a,b,c]
      }
    (Increase ut)-> do 
      { let increase     = updateAmt ut
      ; let outboundAddr = createAddress (updaterPkh ut) (updaterSc ut)
      ; let payout       = Value.singleton (cdtIouPid datum) iouTkn increase
      ; let a = traceIfFalse "Single Script Error"  $ isSingleScript txInputs && isSingleScript txRefInputs -- single in and single ref
      ; let b = traceIfFalse "Cont Payin Error"     $ isValueIncreasing increase                            -- value increases by increase amount
      ; let c = traceIfFalse "Wrong Datum Error"    $ isDatumConstant contOutputs                           -- datum cant change
      ; let d = traceIfFalse "Minting Error"        $ checkMintingProcess increase                          -- mint out the iou tokens
      ; let e = traceIfFalse "Minting Payout Error" $ isAddrGettingPaid txOutputs outboundAddr payout       -- can allow ada too
      ; let f = traceIfFalse "Signing Tx Error"     $ ContextsV2.txSignedBy info (updaterPkh ut)            -- wallet must be signers
      ;         traceIfFalse "Increase Error"       $ all (==True) [a,b,c,d,e,f]
      }
    (Decrease ut)-> do 
      { let decrease     = updateAmt ut
      ; let outboundAddr = createAddress (updaterPkh ut) (updaterSc ut)
      ; let a = traceIfFalse "Single Script Error" $ isSingleScript txInputs && isSingleScript txRefInputs -- single input and single ref
      ; let b = traceIfFalse "Cont Payin Error"    $ isValueDecreasing decrease                            -- the value must decrease by decrease amount
      ; let c = traceIfFalse "Wrong Datum Error"   $ isDatumConstant contOutputs                           -- the datum can not change
      ; let d = traceIfFalse "Burning Error"       $ checkMintingProcess ((-1 :: Integer) * decrease)      -- need to burn iou tokens
      ; let e = traceIfFalse "FT Payout Error"     $ isVotingTokenReturning outboundAddr decrease          -- can allow ada too
      ; let f = traceIfFalse "Signing Tx Error"    $ ContextsV2.txSignedBy info (updaterPkh ut)            -- wallet must sign
      ;         traceIfFalse "Decrease Error"      $ all (==True) [a,b,c,d,e,f]
      }
   where
    info :: PlutusV2.TxInfo
    info = PlutusV2.scriptContextTxInfo context

    contOutputs :: [PlutusV2.TxOut]
    contOutputs = ContextsV2.getContinuingOutputs context

    txInputs :: [PlutusV2.TxInInfo]
    txInputs = PlutusV2.txInfoInputs info

    txOutputs :: [PlutusV2.TxOut]
    txOutputs = PlutusV2.txInfoOutputs info

    txRefInputs :: [PlutusV2.TxInInfo]
    txRefInputs = PlutusV2.txInfoReferenceInputs info

    -- handles mint and burn
    checkMintingProcess :: Integer -> Bool
    checkMintingProcess amt =
      case Value.flattenValue (PlutusV2.txInfoMint info) of
        [(cs, tkn, amt')] -> (cs == cdtIouPid datum) && (tkn == iouTkn) && (amt' == amt)
        _                 -> traceIfFalse "Nothing is Minting" False
    
    isDatumConstant :: [PlutusV2.TxOut] -> Bool
    isDatumConstant []     = False
    isDatumConstant (x:xs) =
      case PlutusV2.txOutDatum x of
        PlutusV2.NoOutputDatum       -> isDatumConstant xs -- datumless
        (PlutusV2.OutputDatumHash _) -> isDatumConstant xs -- embedded datum
        -- inline datum
        (PlutusV2.OutputDatum (PlutusV2.Datum d)) -> 
          case PlutusTx.fromBuiltinData d of
            Nothing     -> isDatumConstant xs
            Just inline -> datum == inline
        
    getVoteValue :: (PlutusV2.CurrencySymbol, PlutusV2.TokenName, Integer) -> Integer
    getVoteValue (_, _, amt) = amt

    createNewValue :: (PlutusV2.CurrencySymbol, PlutusV2.TokenName, Integer) -> Integer -> PlutusV2.Value
    createNewValue (cs, tkn, _) amt = Value.singleton cs tkn amt

    isVotingTokenReturning :: PlutusV2.Address -> Integer -> Bool
    isVotingTokenReturning addr amt = 
      case checkForVoteTokens txRefInputs of
        Nothing        -> False
        Just tokenInfo -> isAddrGettingPaid txOutputs addr (createNewValue tokenInfo amt)
    
    isValueIncreasing :: Integer -> Bool
    isValueIncreasing amt =
      case checkForVoteTokens txRefInputs of
        Nothing        -> False
        Just tokenInfo -> isValueContinuing contOutputs (validatingValue + createNewValue tokenInfo amt)
    
    isValueDecreasing :: Integer -> Bool
    isValueDecreasing amt =
      case checkForVoteTokens txRefInputs of
        Nothing        -> False
        Just tokenInfo -> isValueContinuing contOutputs (validatingValue - createNewValue tokenInfo amt)
    
    hasVotngTokens :: Bool
    hasVotngTokens =
      case checkForVoteTokens txRefInputs of
        Nothing        -> traceIfFalse "Does not have voting tokens" False
        Just tokenInfo -> getVoteValue tokenInfo == (0 :: Integer)
    
    checkForVoteTokens :: [PlutusV2.TxInInfo] -> Maybe (PlutusV2.CurrencySymbol, PlutusV2.TokenName, Integer)
    checkForVoteTokens []     = Nothing
    checkForVoteTokens (x:xs) =
      if traceIfFalse "Incorrect Address" $ (PlutusV2.txOutAddress $ PlutusV2.txInInfoResolved x) == Addr.scriptHashAddress voteValidatorHash
        then
          if traceIfFalse "Incorrect Value" $ Value.geq (PlutusV2.txOutValue $ PlutusV2.txInInfoResolved x) lockValue
            then
              case getReferenceDatum $ PlutusV2.txInInfoResolved x of
                Nothing        -> checkForVoteTokens xs
                Just voteDatum -> Just $ ((vdtPid voteDatum), (vdtTkn voteDatum), (voterTokenValue totalValue (vdtPid voteDatum) (vdtTkn voteDatum)))
            else checkForVoteTokens xs
        else checkForVoteTokens xs

    getReferenceDatum :: PlutusV2.TxOut -> Maybe VoteDatumType
    getReferenceDatum x =
      case PlutusV2.txOutDatum x of
        PlutusV2.NoOutputDatum       -> Nothing -- datumless
        (PlutusV2.OutputDatumHash _) -> Nothing -- embedded datum
        -- inline datum
        (PlutusV2.OutputDatum (PlutusV2.Datum d)) ->
          case PlutusTx.fromBuiltinData d of
            Nothing     -> Nothing
            Just inline -> Just $ PlutusTx.unsafeFromBuiltinData @VoteDatumType inline

    -- token info
    voterTokenValue :: PlutusV2.Value -> PlutusV2.CurrencySymbol -> PlutusV2.TokenName -> Integer
    voterTokenValue totalValue' cur tkn = Value.valueOf totalValue' cur tkn

    totalValue :: PlutusV2.Value
    totalValue = ContextsV2.valueSpent info

    validatingValue :: PlutusV2.Value
    validatingValue =
      case ContextsV2.findOwnInput context of
        Nothing    -> traceError "No Input to Validate." -- This error should never be hit.
        Just input -> PlutusV2.txOutValue $ PlutusV2.txInInfoResolved input
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

representContractScriptShortBs :: SBS.ShortByteString
representContractScriptShortBs = SBS.toShort . LBS.toStrict $ serialise script

representContractScript :: PlutusScript PlutusScriptV2
representContractScript = PlutusScriptSerialised representContractScriptShortBs
