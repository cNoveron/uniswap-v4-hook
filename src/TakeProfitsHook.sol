// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
	// StateLibrary is new here and we haven't seen that before
	// It's used to add helper functions to the PoolManager to read
	// storage values.
	// In this case, we use it for accessing `currentTick` values
	// from the pool manager
	using StateLibrary for IPoolManager;

	// Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

    mapping(PoolId poolId =>
	mapping(int24 tickToSellAt =>
		mapping(bool zeroForOne => uint256 inputAmount)))
        	public pendingOrders;

    mapping(uint256 orderId => uint256 claimsSupply)
        public claimTokensSupply;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

	// Constructor
    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}

	// BaseHook Functions
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function getOrderId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    function placeOrder(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");

        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        // Return the tick at which the order was actually placed
        return tick;
    }

    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick
    ) internal override returns (bytes4) {
		// TODO
        return this.afterInitialize.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
		// TODO
        return (this.afterSwap.selector, 0);
    }

    function getLowerUsableTick(
        int24 tick,
        int24 tickSpacing
    ) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }
}