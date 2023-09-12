# Running tests
aptos move test --named-addresses amnis=0xdollar,deployer=0xdollar,admin=0xdollar,yield=0xdollar

# Deploy instructions
1. Make sure there's an Aptos profile created for the correct network (devnet/testnet/mainnet).
2. aptos move create-resource-account-and-publish-package --profile testnet --named-addresses admin=testnet,deployer=testnet,amnis=[amnis_address] --seed 1 --address-name yield
   Make sure amnis contract address is correct.