// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

// TODO: Ensure all the functions are following CEI pattern
contract CrossChainDex is IAny2EVMMessageReceiver, ReentrancyGuard, OwnerIsCreator {

    //////////////////////////////
    // Type
    //////////////////////////////
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using SafeTransferLib for IERC20;
    struct DexDetails {
        address dexAddress;
        bytes ccipExtraArgsBytes;
    }
    enum ErrorCode {
        // RESOLVED is first so that the default value is resolved.
        RESOLVED,
        // Could have any number of error codes here.
        BASIC
    }

    //////////////////////////////
    // Errors
    //////////////////////////////
    error CrossChainDex__ErrorCase(); // TODO: Remove later
    error CrossChainDex__OnlySelf();
    error CrossChainDex__TransferFailed();
    error CrossChainDex__InvalidRouter(address router);
    error CrossChainDex__NotEnoughBalanceForFees(
        uint256 currentBalance,
        uint256 calculatedFees
    );
    error CrossChainDex__NothingToWithdraw();
    error CrossChainDex__ChainNotEnabled(uint64 chainSelector);
    error CrossChainDex__SenderNotEnabled(uint64 chainSelector, address sender);
    error CrossChainDex__MessageNotFailed(bytes32 messageId);

    //////////////////////////////
    // State Variables
    //////////////////////////////
    bool internal s_simRevert = false; // TODO: Remove this | This is used to simulate a revert in the processMessage function.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;
    IRouterClient internal immutable i_ccipRouter;
    // LinkTokenInterface internal immutable i_linkToken;
    uint64 private immutable i_currentChainSelector;
    mapping(uint64 chainSelector => DexDetails dexDetailsPerChain) public s_chains;
    // Mapping to keep track of the message contents of failed messages.
    mapping(bytes32 messageId => Client.Any2EVMMessage contents) public s_messageContents;

    //////////////////////////////
    // Events
    //////////////////////////////
    event ChainEnabled(
        uint64 chainSelector,
        address dexAddress,
        bytes ccipExtraArgs
    );
    event ChainDisabled(uint64 chainSelector);
    event CrossChainSent(
        bytes32 messageId,
        address from,
        address to,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 swapAtSource,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );
    event CrossChainReceived(
        bytes32 messageId,
        address from,
        address to,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 swapAtSource,
        uint64 sourceChainSelector,
        uint64 destinationChainSelector
    );
    event NativeTokenReceived(
        address from,
        uint256 amount
    );
    event MessageRecovered(bytes32 messageId);
    event MessageFailed(bytes32 messageId, bytes err);

    //////////////////////////////
    // Modifiers
    //////////////////////////////
    modifier onlySelf() {
        if (msg.sender != address(this)) revert CrossChainDex__OnlySelf();
        _;
    }

    modifier onlyRouter() {
        if (msg.sender != address(i_ccipRouter))
            revert CrossChainDex__InvalidRouter(msg.sender);
        _;
    }

    modifier onlyEnabledChain(uint64 chainSelector) {
        if (s_chains[chainSelector].dexAddress == address(0))
            revert CrossChainDex__ChainNotEnabled(chainSelector);
        _;
    }

    modifier onlyEnabledSender(uint64 chainSelector, address sender) {
        if (s_chains[chainSelector].dexAddress != sender)
            revert CrossChainDex__SenderNotEnabled(chainSelector, sender);
        _;
    }

    constructor(
        address ccipRouterAddress,
        uint64 currentChainSelector
    ) {
        if (ccipRouterAddress == address(0)) revert CrossChainDex__InvalidRouter(address(0));
        i_ccipRouter = IRouterClient(ccipRouterAddress);
        i_currentChainSelector = currentChainSelector;
    }

    receive() external payable {
        emit NativeTokenReceived(msg.sender, msg.value);
    }

    function enableChain(
        uint64 chainSelector,
        address dexAddress,
        bytes calldata extraArgs
    ) external onlyOwner {
        s_chains[chainSelector].dexAddress = dexAddress;
        s_chains[chainSelector].ccipExtraArgsBytes = extraArgs;
    }

    // Function to get the fee required to pay for sending the message cross chain
    function getFee(
        uint64 destinationChainSelector,
        Client.EVM2AnyMessage memory message
    ) external view returns (uint256 fee) {
        return i_ccipRouter.getFee(destinationChainSelector, message);
    }

    function getGasFee(
        address from,
        address to,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 swapAtSource,
        uint64 destinationChainSelector
    ) external view returns (uint256 fee) {
        // Create an array with a single EVMTokenAmount
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({ token: tokenIn, amount: amountIn });
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(
                s_chains[destinationChainSelector].dexAddress
            ),
            data: abi.encode(from, to, tokenIn, amountIn, tokenOut, minAmountOut, swapAtSource),
            tokenAmounts: tokenAmounts,
            extraArgs: s_chains[destinationChainSelector].ccipExtraArgsBytes,
            feeToken: address(0) // implying to pay gas in native token
        });
        return i_ccipRouter.getFee(destinationChainSelector, message);
    }

    // 0. Calculate the correct gasLimit to be sent for the destination chain (via Tenderly) - Important for gas optimization
    // TODO: Check the same for different tokens - in case it differs for different tokens

    // 1. Send the token to another chain (pay the fees via native asset) - account for slippage (minAmountOut, default to 0)
    function ccipSend(address from,
        address to,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 swapAtSource,
        uint64 destinationChainSelector
    )
        external
        payable
        nonReentrant
        onlyEnabledChain(destinationChainSelector)
        returns (bytes32 messageId)
    {
        
        if (swapAtSource == 1) {
            // TODO: Swap the tokenIn to tokenOut via a price aggregator
        }

        IERC20(tokenIn).approve(address(i_ccipRouter), amountIn);
        // Create an array with a single EVMTokenAmount
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({ token: tokenIn, amount: amountIn });

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(
                s_chains[destinationChainSelector].dexAddress
            ),
            data: abi.encode(from, to, tokenIn, amountIn, tokenOut, minAmountOut, swapAtSource),
            tokenAmounts: tokenAmounts,
            extraArgs: s_chains[destinationChainSelector].ccipExtraArgsBytes,
            feeToken: address(0) // implying to pay gas in native token
        });

        // Calcuate the fee required in native gas token
        // Get the fee required to send the CCIP message
        uint256 fees = i_ccipRouter.getFee(destinationChainSelector, message);

            // The below can be put in a function
            if (fees > msg.value)
                revert CrossChainDex__NotEnoughBalanceForFees(msg.value, fees);

            // Send the message through the router and store the returned message ID
            messageId = i_ccipRouter.ccipSend{value: fees}(
                destinationChainSelector,
                message
            );
            console2.logBytes32(messageId);
        
        emit CrossChainSent(
            messageId,
            from,
            to,
            tokenIn,
            amountIn,
            tokenOut,
            minAmountOut,
            swapAtSource,
            i_currentChainSelector,
            destinationChainSelector
        );

    }

    /// @notice Allows the owner to toggle simulation of reversion for testing purposes.
    /// @param simRevert If `true`, simulates a revert condition; if `false`, disables the simulation.
    /// @dev This function is only callable by the contract owner.
    function setSimRevert(bool simRevert) external onlyOwner {
        s_simRevert = simRevert;
    }

    // 2. Receive the token on the other chain 
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    )
        external
        override
        nonReentrant
        onlyRouter
        onlyEnabledSender(
            message.sourceChainSelector,
            abi.decode(message.sender, (address))
        ) // Make sure the source chain and sender are enabled
    {
        /* solhint-disable no-empty-blocks */
        try this.processMessage(message) {
            // Intentionally empty in this example; no action needed if processMessage succeeds
        } catch (bytes memory err) {
            // Could set different error codes based on the caught error. Each could be
            // handled differently.
            s_failedMessages.set(
                message.messageId,
                uint256(ErrorCode.BASIC)
            );
            s_messageContents[message.messageId] = message;
            // Don't revert so CCIP doesn't revert. Emit event instead.
            // The message can be retried later without having to do manual execution of CCIP.
            emit MessageFailed(message.messageId, err);
            return;
        }
    }

    function _ccipReceive(Client.Any2EVMMessage calldata message) internal {
        uint64 sourceChainSelector = message.sourceChainSelector;
        (
            address from,
            address to,
            address tokenIn,
            uint256 amountIn,
            address tokenOut,
            uint256 minAmountOut,
            uint256 swapAtSource
        ) = abi.decode(message.data, (address, address, address, uint256, address, uint256, uint256));

        // Put your logic here
        uint256 amountOut;
        // Check if the swap needs to happen here or have been done at the source level
        if (swapAtSource == 2) {
            // TODO: Write the logic to swap the token from tokenIn to tokenOut here
        }

        emit CrossChainReceived(
            message.messageId,
            from,
            to,
            tokenIn,
            amountIn,
            tokenOut,
            amountOut,
            swapAtSource,
            sourceChainSelector,
            i_currentChainSelector
        );
    }

    // TODO: Check if onlyEnabledSender modifier is required here
    /// @notice Serves as the entry point for this contract to process incoming messages.
    /// @param message Received CCIP message.
    /// @dev Processes incoming message. This function
    /// must be internal because of the  try/catch for error handling.
    function processMessage(Client.Any2EVMMessage calldata message) 
        external 
        onlySelf 
        // onlyEnabledSender(
        //     message.sourceChainSelector,
        //     abi.decode(message.sender, (address))
        // )
    {
        // Simulate a revert for testing purposes
        if (s_simRevert) revert CrossChainDex__ErrorCase();

        _ccipReceive(message); // process the message - may revert as well
    }

    /**
     * @notice Retrieves the IDs of failed messages from the `s_failedMessages` map.
     * @dev Iterates over the `s_failedMessages` map, collecting all keys.
     * @return ids An array of bytes32 containing the IDs of failed messages from the `s_failedMessages` map.
     */
    function getFailedMessagesIds()
        external
        view
        returns (bytes32[] memory ids)
    {
        uint256 length = s_failedMessages.length();
        bytes32[] memory allKeys = new bytes32[](length);
        for (uint256 i = 0; i < length; i++) {
            (bytes32 key, ) = s_failedMessages.at(i);
            allKeys[i] = key;
        }
        return allKeys;
    }

    /// @param tokenReceiver The address to which the tokens will be sent.
    /// @dev This function is only callable by the contract owner. It changes the status of the message
    /// from 'failed' to 'resolved' to prevent reentry and multiple retries of the same message.
    function retryFailedMessage(
        bytes32 messageId,
        address tokenReceiver
    ) external onlyOwner {
        // Check if the message has failed; if not, revert the transaction.
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.BASIC))
            revert CrossChainDex__MessageNotFailed(messageId);

        // Set the error code to RESOLVED to disallow reentry and multiple retries of the same failed message.
        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        // Retrieve the content of the failed message. (TODO: Fix this with the correct breakdown of the message retrieved)
        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        // This example expects one token to have been sent, but you can handle multiple tokens.
        // Transfer the associated tokens to the specified receiver as an escape hatch.
        // IERC20(message.destTokenAmounts[0].token).safeTransfer(
        //     tokenReceiver,
        //     message.destTokenAmounts[0].amount
        // );

        // Emit an event indicating that the message has been recovered.
        emit MessageRecovered(messageId);
    }

    function withdrawToken(
        address _beneficiary,
        address _token
    ) public onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));

        if (amount == 0) revert CrossChainDex__NothingToWithdraw();

        IERC20(_token).transfer(_beneficiary, amount);
    }

    function withdrawNativeToken() public onlyOwner {
        uint256 amount = address(this).balance;
        if (amount == 0) revert CrossChainDex__NothingToWithdraw();
        (bool success,) = owner().call{ value: address(this).balance }("");
        if (!success) revert CrossChainDex__TransferFailed();
    }

    // 4. Create the script to ensure that the same dex can receive as well on the other chain, having the same address (via create2)

    // 5. How will you monitor

    // 6. Continegency for errors

}