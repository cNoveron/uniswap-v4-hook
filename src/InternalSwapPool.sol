// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {SwapMath} from '@uniswap/v4-core/src/libraries/SwapMath.sol';
import {Hooks, IHooks} from '@uniswap/v4-core/src/libraries/Hooks.sol';
import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {BeforeSwapDelta, toBeforeSwapDelta} from '@uniswap/v4-core/src/types/BeforeSwapDelta.sol';
import {ModifyLiquidityParams, SwapParams} from '@uniswap/v4-core/src/types/PoolOperation.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {CurrencySettler} from '@uniswap/v4-core/test/utils/CurrencySettler.sol';

import {IERC20Minimal} from '@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';

import {BaseHook} from 'v4-periphery/src/utils/BaseHook.sol';


/**
 * This contract sets up our Uniswap V4 integration, allowing for hook logic to be applied
 * to our pools. This also implements pool fee management and LP reward distribution through
 * the `donate` logic.
 *
 * When fees are collected they will be distributed between the Uniswap V4 pool that was
 * interacted with, to promote liquidity, and an optional beneficiary.
 *
 * The calculation of the fees paid into the {FeeCollector} should be undertaken by the
 * individual contracts that are calling it.
 */
contract InternalSwapPool is BaseHook {

    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Minimum threshold for donations
    uint public constant DONATE_THRESHOLD_MIN = 0.0001 ether;

    /// The native token address
    address public immutable nativeToken;

    /**
     * The amount of claimable tokens that are available to be `distributed` for a `PoolId`.
     *
     * @param amount0 The amount of currency0 that is available to be distributed
     * @param amount1 The amount of currency1 that is available to be distributed
     */
    struct ClaimableFees {
        uint amount0;
        uint amount1;
    }

    /// Maps the amount of claimable tokens that are available to be `distributed`
    /// for a `PoolId`.
    mapping (PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    /**
     * Sets our immutable {PoolManager} contract reference, used to initialise the BaseHook,
     * and also validates that the contract implementing this adheres to the hook address
     * validation.
     */
    constructor (address _poolManager, address _nativeToken) BaseHook(IPoolManager(_poolManager)) {
        nativeToken = _nativeToken;
    }

    /**
     * Provides the {ClaimableFees} for a pool.
     *
     * @param _poolKey The PoolKey of the pool
     *
     * @return The {ClaimableFees} for the pool
     */
    function poolFees(PoolKey calldata _poolKey) public view returns (ClaimableFees memory) {
        return _poolFees[_poolKey.toId()];
    }

    /**
     * When fees are collected against a collection it is sent as ETH in a payable
     * transaction to this function. This then handles the distribution of the
     * allocation between the `_poolId` specified and, if set, a percentage for
     * the `beneficiary`.
     *
     * Our `amount0` must always refer to the amount of the native token provided. The
     * `amount1` will always be the underlying {CollectionToken}. The internal logic of
     * this function will rearrange them to match the `PoolKey` if needed.
     *
     * @param _poolKey The PoolKey of the pool
     * @param _amount0 The amount of currency0 to deposit
     * @param _amount1 The amount of currency1 to deposit
     */
    function depositFees(PoolKey calldata _poolKey, uint _amount0, uint _amount1) public {
        _poolFees[_poolKey.toId()].amount0 += _amount0;
        _poolFees[_poolKey.toId()].amount1 += _amount1;
    }

    /**
     * Before a swap is made, we pull in the dynamic pool fee that we have set to ensure it is
     * applied to the tx.
     *
     * We also see if we have any token1 fee tokens that we can use to fill the swap before it
     * hits the Uniswap pool. This prevents the pool from being affected and reduced gas costs.
     * This also allows us to benefit from the Uniswap routing infrastructure.
     *
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return beforeSwapDelta_ The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     * @return swapFee_ The percentage fee applied to our swap
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) internal override returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_) {
        selector_ = IHooks.beforeSwap.selector;
    }

    /**
     * Once a swap has been made, we distribute fees to our LPs and emit our price update event.
     *
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative)
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook
     *
     * @return selector_ The function selector for the hook
     * @return hookDeltaUnspecified_ The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
     */
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override
    returns (bytes4 selector_, int128 hookDeltaUnspecified_) {
        // Determine the currency that we will be taking our fee
        Currency swapFeeCurrency = params.amountSpecified < 0 == params.zeroForOne ? key.currency1 : key.currency0;

        // Capture the amount received from the swap
        int128 swapAmount = params.amountSpecified < 0 == params.zeroForOne ? delta.amount1() : delta.amount0();

        // Calculate the swap fee and ensure it is a positive uint
        uint swapFee = uint(uint128(swapAmount < 0 ? -swapAmount : swapAmount)) * 99 / 100;

        // Calculate a percentage of the swap amount to capture as the fee. For this hook example we
        // will take 1% of the value that would be received.
        depositFees(
            key,
            params.zeroForOne ? swapFee : 0,
            !params.zeroForOne ? 0 : swapFee
        );

        // Take our swap fees from the {PoolManager}
        swapFeeCurrency.take(poolManager, address(this), swapFee, false);

        // Set our hookDelta to remove the amount of fees from the amount that the user will receive
        hookDeltaUnspecified_ = -int128(int(swapFee));

        // Distribute fees to our LPs
        _distributeFees(key);
        selector_ = IHooks.afterSwap.selector;
    }


    /**
     * Takes a collection address and, if there is sufficient fees available to
     * claim, will call the `donate` function against the mapped Uniswap V4 pool.
     *
     * @dev This call could be checked in a Uniswap V4 interactions hook to
     * dynamically process fees when they hit a threshold.
     *
     * @param _poolKey The PoolKey reference that will have fees distributed
     */
    function _distributeFees(PoolKey calldata _poolKey) internal {
        // Get the amount of the native token available to donate
        PoolId poolId = _poolKey.toId();
        uint donateAmount = _poolFees[poolId].amount0;

        // Ensure that the collection has sufficient fees available
        if (donateAmount < DONATE_THRESHOLD_MIN) {
            return;
        }

        // Make our donation to the pool
        BalanceDelta delta = poolManager.donate(_poolKey, donateAmount, 0, '');

        // Check the native delta amounts that we need to transfer from the contract
        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, address(this), uint(uint128(-delta.amount0())), false);
        }

        // Reduce our available fees
        _poolFees[poolId].amount0 -= donateAmount;
    }

    /**
     * This function defines the hooks that are required, and also importantly those which are
     * not, by our contract. This output determines the contract address that the deployment
     * must conform to and is validated in the constructor of this contract.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

}