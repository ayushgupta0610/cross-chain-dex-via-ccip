// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";
import {LinkTokenInterface} from "@chainlink/contracts-ccip/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";

contract ReceiverDex is CCIPReceiver, OwnerIsCreator {
    //////////////////////////////
    // Errors
    //////////////////////////////
    error CrossChainDex__InvalidRouter(address router);

    //////////////////////////////
    // State Variables
    //////////////////////////////
    // LinkTokenInterface internal immutable i_linkToken;
    uint64 private immutable i_currentChainSelector;
    // mapping(uint64 destChainSelector => DexDetails dexDetailsPerChain)public s_chains;
    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 chainSelecotor => bool isAllowlisted) public allowlistedSourceChains;

    //////////////////////////////
    // Events
    //////////////////////////////
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

    constructor(
        address ccipRouterAddress,
        uint64 currentChainSelector
    ) CCIPReceiver(ccipRouterAddress) {
        if (ccipRouterAddress == address(0))
            revert CrossChainDex__InvalidRouter(address(0));
        i_currentChainSelector = currentChainSelector;
    }

    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool _allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    )
        internal
        virtual
        override
        onlyRouter
        // nonReentrant
        // onlyEnabledChain(message.sourceChainSelector)
        // onlyEnabledSender(
        //     message.sourceChainSelector,
        //     abi.decode(message.sender, (address))
        // )
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

}