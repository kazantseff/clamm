// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./TickMath.sol";

library Tick {
    struct Info {
        // @audit Not sure what exactly is liquidityGross and liquidityNet
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left)
        int128 liquidityNet;
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // Whether this tick is initalized or not
        bool initialized;
    }

    // Returns max liquidity per tick
    function tickSpacingToMaxLiquidityPerTick(
        int24 tickSpacing
    ) internal pure returns (uint128) {
        // Calculates minTick and maxTick as multiples of tickSpacing
        // i.e if tickSpacing is 10 => (887272 / 10) * 10 => 887270
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        // Calculate totalNumber of ticks, if tickSpacing is 10 => (887270 - (-887270)) + 1 => 177455
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        // Divide totalLiquidity by number of ticks, which will give us a maxAmountOfLiquidity per tick
        return type(uint128).max / numTicks;
    }

    function update(
        mapping(int24 => Info) storage self,
        // tick that is being updated
        int24 tick,
        // current tick (stored slot0)
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        // Upper or lower tick
        bool upper,
        uint256 maxLiquidity
    )
        internal
        returns (
            // Flipped - if tick becomes active or inactive
            bool flipped
        )
    {
        Info storage info = self[tick];

        // The total amount of liquidty in tick before update
        uint128 liquidityGrossBefore = info.liquidityGross;
        // Amount of liquidity after update
        uint128 liquidityGrossAfter = liquidityDelta < 0
            ? liquidityGrossBefore - uint128(-liquidityDelta)
            : liquidityGrossBefore + uint128(liquidityDelta);

        require(
            liquidityGrossAfter <= maxLiquidity,
            "Liquidity exceeds maxLiquidity"
        );

        // flipped = (liquidityGrossBefore == 0 && liquidityGrossAfer > 0)
        //         || (liquidityGrossBefore > 0 && liquidityGrossaAfer == 0)
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        // If liquidity before update was 0, that means that tick was inactive, thus we need to initialize it
        if (liquidityGrossBefore == 0) {
            info.initialized = true;
        }

        info.liquidityGross = liquidityGrossAfter;

        // lower     upper
        //   |         |
        //   +         -
        // ----> one for zero +
        // <---- zero for one -

        info.liquidityNet = upper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;
    }

    function clear(mapping(int24 => Info) storage self, int24 tick) internal {
        delete self[tick];
    }
}
