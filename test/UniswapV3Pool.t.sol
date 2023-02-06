// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import 'forge-std/Test.sol';
import './ERC20Mintable.sol';
import '../src/UniswapV3Pool.sol';

contract UniswapV3PoolTest is Test {

	ERC20Mintable token0;
	ERC20Mintable token1;
	UniswapV3Pool pool;
	bool shouldTransferInMintCallback;

	struct TestCaseParams {
		uint256 wethBalance;
		uint256 usdcBalance;
		int24 currentTick;
		int24 lowerTick;
		int24 upperTick;
		uint128 liquidity;
		uint160 currentSqrtP;
		bool transferInMintCallback;
		bool transferInSwapCallback;
		bool mintLiqudity;
	}

	function setUp() public {
		token0 = new ERC20Mintable('Ether', 'ETH', 18);
		token1 = new ERC20Mintable('USDC', 'USDC', 18);
	}

	function testMintSuccess() public pure {
		// deposit 1 ETH and 5000 USDC
		TestCaseParams memory params = TestCaseParams({
			wethBalance: 1 ether,
			usdcBalance: 5000 ether,
			currentTick: 85176,
			lowerTick: 84222,
			upperTick: 86129,
			liquidity: 1517882343751509868544,
			currentSqrtP: 5602277097478614198912276234240,
			transferInMintCallback: true,
			transferInSwapCallback: true,
			mintLiqudity: true
		});
	}

	function setupTestCase(TestCaseParams memory params) internal returns (uint256 poolBalance0, uint256 poolBalance1) {
		token0.mint(address(this), params.wethBalance);
		token1.mint(address(this), params.usdcBalance);
		pool = new UniswapV3Pool(address(token0), address(token1), params.currentSqrtP, params.currentTick);

		if (params.mintLiqudity) {
			(poolBalance0, poolBalance1) = pool.mint(
				address(this), 
				params.lowerTick, 
				params.upperTick, 
				params.liquidity, 
				abi.encode(params.transferInMintCallback)
			);
		}

		shouldTransferInMintCallback = params.transferInMintCallback;
	}

	function uniswapV3MintCallback(uint256 amount0, uint256 amount1) external {
		if (shouldTransferInMintCallback) {
			token0.transferFrom(msg.sender, address(this), amount0);
			token1.transferFrom(msg.sender, address(this), amount1);
		}
	}

	function testExample() public {
		assertTrue(true);
	}
}