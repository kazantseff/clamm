// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./lib/Tick.sol";
import "./lib/TickMath.sol";
import "./lib/Position.sol";
import "./lib/SafeCast.sol";
import "./interfaces/IERC20.sol";
import "./lib/SqrtPriceMath.sol";

contract CLAMM {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Tick for mapping(int24 => Tick.Info);
    using Tick for Tick.Info;

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    struct Slot0 {
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
        bool locked;
    }

    Slot0 public slot0;

    struct ModifyPositionParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    uint128 public liquidity;
    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;

    modifier lock() {
        require(slot0.locked == false, "contract is locked");
        slot0.locked = true;
        _;
        slot0.locked = false;
    }

    constructor(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickSpacing
    ) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        // Number of ticks to skip when the price moves
        // When there is a trade => price increases or decreases in steps of tick spacing
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(
            _tickSpacing
        );
    }

    function initialize(uint160 sqrtPriceX96) external {
        // price = (sqrtPriceX96 / 2**96) ** 2
        require(slot0.sqrtPriceX96 == 0, "already initialized");

        // (sqrtPriceX96 / 2**96) ** 2 = 1.0001**tick
        // log((sqrtPriceX96 / 2**96) ** 2) = log(1.0001**tick)
        // 2log(sqrtPriceX96 / 2**96) = ticklog(1.0001)
        // tick = (2log(sqrtPriceX96 / 2**96)) / log(1.0001)
        int24 currentTick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: currentTick,
            locked: false
        });
    }

    function balance0() private view returns (uint256) {
        return IERC20(token0).balanceOf(address(this));
    }

    function balance1() private view returns (uint256) {
        return IERC20(token1).balanceOf(address(this));
    }

    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        require(tickLower < tickUpper);
        require(tickLower >= TickMath.MIN_TICK);
        require(tickUpper <= TickMath.MAX_TICK);
    }

    function _updatePosition(
        address owner,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        // positions.get(,,) is equivalent to get(positions,,,)
        position = positions.get(owner, tickLower, tickUpper);

        // #TODO: Fees
        uint256 _feeGrowthGlobal0X128 = 0;
        uint256 _feeGrowthGlobal1X128 = 0;

        bool flippedLower;
        bool flippedUpper;
        // If there is a change in liquidity, we need to update the tick
        if (liquidityDelta != 0) {
            // Update the lower tick and see if it was flipped
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                maxLiquidityPerTick
            );
            // Update the upper tick and see if it was flipped
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                true,
                maxLiquidityPerTick
            );
        }

        // Updating position in storage
        position.update(liquidityDelta, 0, 0);

        // If liquidity was removed and tick is flipped because of that => it meants tick became inactive
        if (liquidityDelta < 0) {
            if (flippedLower) {
                Tick.clear(ticks, tickLower);
            }

            if (flippedUpper) {
                Tick.clear(ticks, tickUpper);
            }
        }
    }

    // modifying a position by liquidityDelta
    function _modifyPosition(
        ModifyPositionParams memory params
    )
        private
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0; // gas optimization

        // Updating position in storage
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            // current tick
            _slot0.tick
        );

        // Returning amount0 and amount1
        if (params.liquidityDelta != 0) {
            // When a price is lesser than Pa in a lower price range, liquidity is all token0
            if (_slot0.tick < params.tickLower) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // When the price is between Pa and Pb
            } else if (_slot0.tick < params.tickUpper) {
                // From the current price to the upper price
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // From the lower price to the current price
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // Update current liquidity as the price is in the active range
                liquidity = params.liquidityDelta < 0
                    ? liquidity - uint128(-params.liquidityDelta)
                    : liquidity + uint128(params.liquidityDelta);

                // When the price is greater than Pb, in a greater price range, liquidity is all in token1
            } else if (_slot0.tick > params.tickUpper) {
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    /**
     *
     * @param recepient owner of the position
     * @param tickLower lower tick of the position
     * @param tickUpper upper tick of the position
     * @param amount amount of liquidity to add
     * @return amount0 amount of token0 required
     * @return amount1 amount of token1 required
     */
    function mint(
        address recepient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0);
        // Get the amount of token0 and token1 required to provied "amount" of liquidity
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recepient,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(amount)).toInt128()
            })
        );

        // Since we are adding liquidity, it's safe to cast to uint, since the amount is positive
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;

        // Cache balances before
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();

        // transfer tokens from user
        if (amount0 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }

        if (amount1 > 0) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }

        // Check that enough tokens were sent
        require(balance0Before + amount0 <= balance0());
        require(balance1Before + amount1 <= balance1());
    }

    function collect(
        address recepient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external lock returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(
            msg.sender,
            tickLower,
            tickUpper
        );

        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recepient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recepient, amount1);
        }
    }

    /**
     * @param tickLower Lower tick of the position
     * @param tickUpper Upper tick of the position
     * @param amount Amount of liquidity to remove
     * @return amount0
     * @return amount1
     */
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external lock returns (uint256 amount0, uint256 amount1) {
        (
            Position.Info storage position,
            int256 amount0Int,
            int256 amount1Int
        ) = _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: -int256(uint256(amount)).toInt128()
                })
            );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            position.tokensOwed0 += uint128(amount0);
            position.tokensOwed1 += uint128(amount1);
        }
    }
}
