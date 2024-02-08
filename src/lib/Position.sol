// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // In original code it says fees, while it does not seem to be fees???
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Info storage position) {
        return self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        // If liquidity delta is 0, disallow pokes for 0 liquidity positions
        if (liquidityDelta == 0) {
            require(self.liquidity > 0, "0 liquidity");
        } // @audit In the original code here in else clause the code calculates liquidityNext by adding liquidity delta

        // If there is a change in liquidity
        if (liquidityDelta != 0) {
            // Update position's liquidity
            _self.liquidity = liquidityDelta < 0
                ? _self.liquidity - uint128(-liquidityDelta) // Substract from current position liquidity if liquidityDelta is negative
                : _self.liquidity + uint128(liquidityDelta); // Add to current position liquidity if liquidityDelta is positive
        }
    }
}
