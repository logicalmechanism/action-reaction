import Prelude
import Cardano.Api
import MintingContract ( mintingPlutusScript )

main :: IO ()
main = do
  result <- writeFileTextEnvelope "minting-contract.plutus" Nothing mintingPlutusScript
  case result of
    Left err -> print $ displayError err
    Right () -> return ()