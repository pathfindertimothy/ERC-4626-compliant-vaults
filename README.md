## ERC-4626 Compliant Vault

## Instruction
- Make sure Foundry is install on the machine
- Clone the repo from: `No instruction was given to upload to github`. 
- Repo is in Google Drive Foler
- Make a copy of `.env.example` as `.env` and fill in the required details

## To Run Test
- To compile run: `forge compile`
- To run the test run: `forge test -vvv`

## To Run on HyperEVM Testnet
```shell
$ forge script script/DeployMultiStrategy4626Vault.s.sol:DeployMultiStrategy4626Vault \
  --rpc-url hyperevm_testnet \
  --chain-id XXX \
  --broadcast \
  -vvvv
```

## To Run on HyperEVM Testnet and verify
```shell
$ forge script script/DeployMultiStrategy4626Vault.s.sol:DeployMultiStrategy4626Vault \
  --rpc-url $RPC_URL_SEPOPLIA \
  --chain-id $CHAIN_ID_SEPOLIA \
  --broadcast \
  --verify \
  -vvvv
```