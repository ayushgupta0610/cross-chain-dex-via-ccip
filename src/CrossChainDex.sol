// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

contract CrossChainDex is IAny2EVMMessageReceiver, ReentrancyGuard, OwnerIsCreator {

    //////////////////////////////
    // Errors
    //////////////////////////////
    error CrossChainDex__InvalidRouter(address router);
    error CrossChainDex__NotEnoughBalanceForFees(
        uint256 currentBalance,
        uint256 calculatedFees
    );
    error CrossChainDex__NothingToWithdraw();
    error CrossChainDex__ChainNotEnabled(uint64 chainSelector);
    error CrossChainDex__SenderNotEnabled(address sender);
    error CrossChainDex__OperationNotAllowedOnCurrentChain(uint64 chainSelector);
    error CrossChainDex__DestinationChainNotAllowlisted(uint64 chainSelector);

    //////////////////////////////
    // Type
    //////////////////////////////
    using SafeTransferLib for IERC20;
    struct DexDetails {
        address dexAddress;
        bytes ccipExtraArgsBytes;
    }

    //////////////////////////////
    // State Variables
    //////////////////////////////
    IRouterClient internal immutable i_ccipRouter;
    // LinkTokenInterface internal immutable i_linkToken;
    uint64 private immutable i_currentChainSelector;
    mapping(uint64 chainSelector => DexDetails dexDetailsPerChain) public s_chains;
    // mapping(uint64 => uint256) public allowlistedChains; // used uint256 instead of bool for gas optimization

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

    //////////////////////////////
    // Modifiers
    //////////////////////////////
    modifier onlyRouter() {
        if (msg.sender != address(i_ccipRouter))
            revert CrossChainDex__InvalidRouter(msg.sender);
        _;
    }

    modifier onlyEnabledChain(uint64 _chainSelector) {
        if (s_chains[_chainSelector].dexAddress == address(0))
            revert CrossChainDex__ChainNotEnabled(_chainSelector);
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

    // 0. Calculate the correct gasLimit to be sent for the destination chain (via Tenderly) - Important for gas optimization
    // Check the same for different tokens - in case it differs for different tokens

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
        // TODO: Ensure this function is following CEI pattern
        if (swapAtSource == 1) {
            // TODO: Swap the tokenIn to tokenOut via a price aggregator
        }
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

    // 2. Receive the token on the other chain 
    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(
        Client.Any2EVMMessage calldata message
    )
        external
        virtual
        override
        onlyRouter
        nonReentrant
        onlyEnabledChain(message.sourceChainSelector)
    {
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

    // 3. Check if enable chain and sender is required for deploying to multiple chains - modifiers in place for the same


    // 4. Create the script to ensure that the same dex can receive as well on the other chain, having the same address (via create2)





}