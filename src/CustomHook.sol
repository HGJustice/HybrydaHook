// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {FearAndGreedIndexConsumer} from "./FearAndGreedIndexConsumer.sol";

contract CustomHook is BaseHook, FearAndGreedIndexConsumer {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    uint24 public constant BASE_FEE = 5000;

    struct Position {
        int24 tickUpper;
        int24 tickLower;
        uint128 amount0;
        uint128 amount1;
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
    mapping(address => uint256) public outOfRangeFees;

    Position[] public inRangePositions;
    Position[] public outOfRangePositions;

    error MustUseDynamicFee();
    error NoHookDataProvided();
    error NoAddressGiven();
    error InvalidPositionID();
    error NotOwner();

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
            // get the current tick in the pool
            (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
            // check if params of the addeed liq is in range of the current tick
            bool inRange = params.tickLower <= currentTick &&
                currentTick < params.tickUpper;
            if (inRange) {
                // if in range give bool true
                Position memory newPosition = Position({
                    tickUpper: params.tickUpper,
                    tickLower: params.tickLower,
                    amount0: uint128(delta.amount0()),
                    amount1: uint128(delta.amount1()),
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
                // else not
                Position memory newPosition = Position({
                    tickUpper: params.tickUpper,
                    tickLower: params.tickLower,
                    amount0: uint128(delta.amount0()),
                    amount1: uint128(delta.amount1()),
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
            // laslty if user just adding to current position just add liquiuduty
            userPositions[currentUser][currentUserNonce].amount0 += uint128(
                delta.amount0()
            );
            userPositions[currentUser][currentUserNonce].amount1 += uint128(
                delta.amount1()
            );
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
            currentPosition.amount0 -= uint128(delta.amount0());
            currentPosition.amount1 -= uint128(delta.amount1());

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
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        (uint24 inRangeFee, uint24 outRangeFee) = calculateFeeSplit();
        uint24 adjustedInRangeFee = getFearNGreedFee(inRangeFee);

        uint24 feeWithFlag = adjustedInRangeFee |
            LPFeeLibrary.OVERRIDE_FEE_FLAG;
        int128 deltaAmount;

        if (params.zeroForOne) {
            uint256 inputAmount = uint256(
                params.amountSpecified < 0
                    ? -params.amountSpecified
                    : params.amountSpecified
            );
            uint256 feeAmount = (inputAmount * uint256(outRangeFee)) / 1000000;
            deltaAmount = int128(uint128(feeAmount));
        } else {
            uint256 inputAmount = uint256(
                params.amountSpecified < 0
                    ? -params.amountSpecified
                    : params.amountSpecified
            );
            uint256 feeAmount = (inputAmount * uint256(outRangeFee)) / 1000000;
            deltaAmount = int128(uint128(feeAmount));
        }

        BeforeSwapDelta delta;
        if (params.zeroForOne) {
            // If swapping token0 for token1, we take some token0 (specified token)
            delta = toBeforeSwapDelta(deltaAmount, 0);
        } else {
            // If swapping token1 for token0, we take some token1 (specified token)
            delta = toBeforeSwapDelta(0, deltaAmount);
        }
        return (this.beforeSwap.selector, delta, feeWithFlag);
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

    function claimFees() external {
        // check if person claiming is owner
        uint256 fees = outOfRangeFees[msg.sender];
        // allow to take x amount form pool manager to send to user??
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
        //check inRange positions
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
                i--;
            }
        }
        //check outRange positions
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
                i--;
            }
        }
        return (this.afterSwap.selector, 0);
    }
}
