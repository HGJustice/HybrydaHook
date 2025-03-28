// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {FearAndGreedIndexConsumer} from "./FearAndGreedIndexConsumer.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {console} from "forge-std/console.sol";

contract CustomHook is BaseHook, FearAndGreedIndexConsumer {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using CurrencySettler for Currency;

    uint24 public constant BASE_FEE = 5000;

    struct Position {
        int24 tickUpper;
        int24 tickLower;
        uint128 liquidity;
        bool inRange;
        uint256 nonce;
        bool exists;
        address owner;
    }

    uint128 public inRangeLiquidity = 0;
    uint128 public outRangeLiquidity = 0;

    mapping(address => mapping(uint256 => Position)) public userPositions;
    mapping(address => uint256) public nonceCount;
    mapping(address => mapping(Currency => uint256)) outOfRangeFees;

    Position[] public inRangePositions;
    Position[] public outOfRangePositions;

    error MustUseDynamicFee();
    error NoHookDataProvided();
    error NoAddressGiven();
    error InvalidPositionID();
    error NotOwner();
    error NoFeesToWithdraw();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) revert NoHookDataProvided();
        address currentUser = abi.decode(hookData, (address));
        if (currentUser == address(0)) revert NoAddressGiven();
        uint256 currentUserNonce = nonceCount[currentUser];

        if (!userPositions[currentUser][currentUserNonce].exists) {
            (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());

            bool inRange = params.tickLower <= currentTick &&
                currentTick < params.tickUpper;
            if (inRange) {
                Position memory newPosition = Position({
                    tickUpper: params.tickUpper,
                    tickLower: params.tickLower,
                    liquidity: uint128(uint256(params.liquidityDelta)),
                    nonce: currentUserNonce,
                    inRange: true,
                    exists: true,
                    owner: currentUser
                });
                inRangePositions.push(newPosition);
                userPositions[currentUser][currentUserNonce] = newPosition;
                inRangeLiquidity += uint128(uint256(params.liquidityDelta));
            } else {
                Position memory newPosition = Position({
                    tickUpper: params.tickUpper,
                    tickLower: params.tickLower,
                    liquidity: uint128(uint256(params.liquidityDelta)),
                    inRange: false,
                    nonce: currentUserNonce,
                    exists: true,
                    owner: currentUser
                });
                outOfRangePositions.push(newPosition);
                userPositions[currentUser][currentUserNonce] = newPosition;
                outRangeLiquidity += uint128(uint256(params.liquidityDelta));
            }
            nonceCount[currentUser] = currentUserNonce + 1;
        } else {
            userPositions[currentUser][currentUserNonce].liquidity += uint128(
                uint256(params.liquidityDelta)
            );
        }
        return (this.afterAddLiquidity.selector, delta);
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        if (hookData.length == 0) revert NoHookDataProvided();
        (address currentUser, uint256 positionNonce) = abi.decode(
            hookData,
            (address, uint256)
        );
        if (currentUser == address(0)) revert NoAddressGiven();
        uint256 currentUserNonce = nonceCount[currentUser];
        if (positionNonce >= currentUserNonce) revert InvalidPositionID();

        Position storage currentPosition = userPositions[currentUser][
            positionNonce
        ];

        if (currentPosition.exists) {
            currentPosition.liquidity -= uint128(
                uint256(-params.liquidityDelta)
            );

            if (currentPosition.inRange) {
                inRangeLiquidity -= uint128(uint256(-params.liquidityDelta));
            } else {
                outRangeLiquidity -= uint128(uint256(-params.liquidityDelta));
            }

            if (currentPosition.liquidity == 0) {
                currentPosition.exists = false;
            }
        }
        return (this.afterRemoveLiquidity.selector, delta);
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (uint24 inRangeFeeSplit, uint24 outRangeFeeSplit) = calculateFeeSplit();
        uint24 feeWithFlag = getFearNGreedFee(inRangeFeeSplit) |
            LPFeeLibrary.OVERRIDE_FEE_FLAG;

        uint256 absAmount;
        if (params.amountSpecified < 0) {
            absAmount = uint256(-params.amountSpecified);
        } else {
            absAmount = uint256(params.amountSpecified);
        }

        uint256 feeAmount = (absAmount * outRangeFeeSplit) / 10000;
        int128 delta = int128(int256(feeAmount));
        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(delta, 0);
        settleFees(key, params.zeroForOne, feeAmount);
        distributeFees(key, params.zeroForOne, feeAmount);

        return (this.beforeSwap.selector, beforeSwapDelta, feeWithFlag);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        Position[] storage outRangeUsers = outOfRangePositions;
        Position[] storage inRangeUsers = inRangePositions;

        for (uint i = 0; i < inRangeUsers.length; i++) {
            Position storage currentPositon = inRangeUsers[i];
            if (
                currentPositon.exists &&
                (currentTick < currentPositon.tickLower ||
                    currentTick >= currentPositon.tickUpper)
            ) {
                currentPositon.inRange = false;
                outRangeUsers.push(currentPositon);

                inRangeLiquidity -= currentPositon.liquidity;
                outRangeLiquidity += currentPositon.liquidity;

                inRangeUsers[i] = inRangeUsers[inRangeUsers.length - 1];
                inRangeUsers.pop();
            }
        }

        for (uint i = 0; i < outRangeUsers.length; i++) {
            Position storage currentPosition = outRangeUsers[i];
            if (
                currentPosition.exists &&
                (currentPosition.tickLower <= currentTick &&
                    currentTick < currentPosition.tickUpper)
            ) {
                currentPosition.inRange = true;
                inRangeUsers.push(currentPosition);

                outRangeLiquidity -= currentPosition.liquidity;
                inRangeLiquidity += currentPosition.liquidity;

                outRangeUsers[i] = outRangeUsers[outRangeUsers.length - 1];
                outRangeUsers.pop();
            }
        }
        return (this.afterSwap.selector, 0);
    }

    function claimFees(Currency token) external {
        uint256 amount = outOfRangeFees[msg.sender][token];
        if (amount == 0) {
            revert NoFeesToWithdraw();
        }
        outOfRangeFees[msg.sender][token] = 0;

        token.transfer(msg.sender, amount);
    }

    function distributeFees(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 feeAmount
    ) internal {
        if (outRangeLiquidity == 0) return;
        Currency token0 = key.currency0;
        Currency token1 = key.currency1;

        Currency tokenToDistribute = zeroForOne ? token0 : token1;

        for (uint i = 0; i < outOfRangePositions.length; i++) {
            Position memory currentPosition = outOfRangePositions[i];
            if (currentPosition.exists) {
                uint256 positionShare = (feeAmount *
                    currentPosition.liquidity) / outRangeLiquidity;
                outOfRangeFees[currentPosition.owner][
                    tokenToDistribute
                ] += positionShare;
            }
        }
    }

    function settleFees(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 feeAmount
    ) internal {
        if (zeroForOne) {
            key.currency0.take(poolManager, address(this), feeAmount, false);
        } else {
            key.currency1.take(poolManager, address(this), feeAmount, false);
        }
    }

    function calculateFeeSplit()
        internal
        view
        returns (uint24 inRangeFee, uint24 outRangeFee)
    {
        uint128 totalLiq = inRangeLiquidity + outRangeLiquidity;

        if (totalLiq == 0) {
            return (0, 0);
        }

        uint256 inRangePercentage = (uint256(inRangeLiquidity) * 10000) /
            uint256(totalLiq);
        uint256 outRangePercentage = 10000 - inRangePercentage;

        inRangeFee = uint24((uint256(BASE_FEE) * inRangePercentage) / 10000);
        outRangeFee = uint24((uint256(BASE_FEE) * outRangePercentage) / 10000);
        return (inRangeFee, outRangeFee);
    }

    function getFearNGreedFee(uint24 feeAmount) internal view returns (uint24) {
        uint fearNGreed = index;
        if (fearNGreed < 20) {
            // Extreme fear
            return feeAmount * 2;
        } else if (fearNGreed < 40) {
            // Fear
            return (feeAmount * 15) / 10;
        } else if (fearNGreed < 60) {
            // Neutral
            return feeAmount;
        } else if (fearNGreed < 80) {
            // Greed
            return (feeAmount * 15) / 10;
        } else {
            // Extreme greed
            return feeAmount * 2;
        }
    }

    function getOutOfRangeFees(
        address user,
        Currency token
    ) external view returns (uint256) {
        return outOfRangeFees[user][token];
    }
}
