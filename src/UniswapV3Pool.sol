// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;
import './lib/Tick.sol';
import './lib/Position.sol';
import './lib/TickBitmap.sol';
import './lib/Math.sol';
import './lib/TickMath.sol';
import './lib/SwapMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV3MintCallback.sol';
import './interfaces/IUniswapV3SwapCallback.sol';

contract UniswapV3Pool {
    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using TickBitmap for mapping(int16 => uint256);

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Pool tokens, immutable
    address public immutable token0;
    address public immutable token1;

    // Packing variables that are read together
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
    }

    Slot0 public slot0;

    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
    }

    // Amount of liquidity, L.
    uint128 public liquidity;

    // Ticks info
    mapping(int24 => Tick.Info) public ticks;
    // Positions info
    mapping(bytes32 => Position.Info) public positions;
    // Tick bitmap
    mapping(int16 => uint256) public tickBitmap;


    // ERRORS
    error InsufficientInputAmount();
    error InvalidTickRange();
    error ZeroLiquidity();

    //EVENTS
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    constructor(
        address token0_,
        address token1_,
        uint160 sqrtPriceX96,
        int24 tick
    ) {
        token0 = token0_;
        token1 = token1_;

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick
        });
    }

    function mint(
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        bytes calldata data
        // given L(amount), and lower & upper ticks, calculate 
        // how much x and y to mint
        // note: L will be given by periphery contracts
    ) external returns (uint256 amount0, uint256 amount1) {
        if (
            lowerTick >= upperTick ||
            lowerTick < MIN_TICK ||
            upperTick > MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();

        ticks.update(lowerTick, amount);
        ticks.update(upperTick, amount);

        bool flippedLower = ticks.update(lowerTick, amount);
        bool flippedUpper = ticks.update(upperTick, amount);

        if (flippedLower) {
            tickBitmap.flipTick(lowerTick, 1);
        }

        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, 1);
    }

        Position.Info storage position = positions.get(
            owner,
            lowerTick,
            upperTick
        );
        position.update(amount);

        Slot0 memory slot0_ = slot0;


        amount0 = Math.calcAmount0Delta(
            TickMath.getSqrtRatioAtTick(slot0_.tick),
            TickMath.getSqrtRatioAtTick(upperTick),
            amount
        );

        amount1 = Math.calcAmount1Delta(
            TickMath.getSqrtRatioAtTick(slot0_.tick),
            TickMath.getSqrtRatioAtTick(lowerTick),
            amount
        );

        liquidity += uint128(amount);


        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();
        
        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
    }

    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }
    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }

    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        bytes calldata data
    ) public returns (
        int256 amount0,
        int256 amount1
    ) {
        Slot0 memory slot0_ = slot0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });

        while (state.amountSpecifiedRemaining > 0) {
            StepState memory step;

            //get the starting point of the price range
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            // get the next available tick
            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                1,
                zeroForOne
            );

            // get the ending point of the price range
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            // caculate the new current price the swap will result in, and amount swapped in and out
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath
                .computeSwapStep(
                    step.sqrtPriceStartX96,
                    step.sqrtPriceNextX96,
                    liquidity,
                    state.amountSpecifiedRemaining
                );

            // update the state
            state.amountSpecifiedRemaining -= step.amountIn;
            state.amountCalculated += step.amountOut;
            state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
        }

        // update the state
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }

        // get the ending amounts of two tokens after the swap
        (amount0, amount1) = zeroForOne
            ? (
                int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated)
            )
            : (
                -int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining)
            );

        // transfer the tokens to the recipient
        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
                amount0,
                amount1,
                data
            );
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(
            msg.sender,
            recipient,
            amount0,
            amount1,
            slot0.sqrtPriceX96,
            liquidity,
            slot0.tick
        );
    }
}