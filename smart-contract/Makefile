.PHONY: install build test test-fuzz gas deploy-monad clean

install:
	forge install OpenZeppelin/openzeppelin-contracts smartcontractkit/chainlink-brownie-contracts --no-git

build:
	forge build

test:
	forge test -vv

test-fuzz:
	forge test --match-path test/OneStrokeTradeRegistryFuzz.t.sol -vvv

gas:
	forge test --gas-report

deploy-monad:
	forge script script/Deploy.s.sol --rpc-url $(MONAD_RPC_URL) --broadcast --private-key $(PRIVATE_KEY)

clean:
	forge clean
