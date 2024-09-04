// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console, Vm} from "forge-std/Test.sol";
import {CrossChainDex} from "../src/CrossChainDex.sol";
// import {ReceiverDex} from "../src/ReceiverDex.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/src/v0.8/ccip/test/mocks/MockRouter.sol";

contract CrossChainDexTest is Test {
    
    address private constant BOB = 0x47D1111fEC887a7BEb7839bBf0E1b3d215669D86;
    uint256 private constant AMOUNT = 1000_000;
    // Avalanche Fuji Testnet constants
    uint64 private constant FUJI_CHAIN_SELECTOR = 14767482510784806043;
    address private constant FUJI_USDC_TOKEN = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address private constant FUJI_LINK_TOKEN = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;
    // address private constant FUJI_ROUTER_ADDRESS = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;

    // Ethereum Sepolia Testnet constants
    uint64 private constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    address private constant SEPOLIA_USDC_TOKEN = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    // address private constant SEPOLIA_ROUTER_ADDRESS = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    CrossChainDex private senderCrossChainDex;
    CrossChainDex private receiverCrossChainDex;
    CCIPLocalSimulatorFork private ccipLocalSimulatorFork;
    MockCCIPRouter private router;

    uint256 avaxFujiFork;
    uint256 ethSepoliaFork;

    function setUp() public {
        
        string memory AVALANCHE_FUJI_RPC_URL = vm.envString("AVALANCHE_FUJI_RPC_URL");
        string memory ETHEREUM_SEPOLIA_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        avaxFujiFork = vm.createSelectFork(AVALANCHE_FUJI_RPC_URL);
        ethSepoliaFork = vm.createFork(ETHEREUM_SEPOLIA_RPC_URL);

        // vm.prank(BOB);
        // IERC20(FUJI_USDC_TOKEN).transfer(address(this), AMOUNT);

        // Step 0) Deploy CCIPLocalSimulatorFork and MockCCIPRouter to get the setup ready
        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        router = new MockCCIPRouter();
        vm.makePersistent(address(ccipLocalSimulatorFork), address(router));

        // Step 1) Deploy CrossChainDex.sol to Avalanche Fuji
        assertEq(vm.activeFork(), avaxFujiFork);
        senderCrossChainDex = new CrossChainDex(address(router), FUJI_CHAIN_SELECTOR);
        console.log("CrossChainDex deployed to: ", address(senderCrossChainDex));
        vm.prank(BOB);
        IERC20(FUJI_USDC_TOKEN).approve(address(senderCrossChainDex), AMOUNT);

        // Step 2) Switch network to Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);
        assertEq(vm.activeFork(), ethSepoliaFork);

        // Step 3) Deploy ReceiverDex.sol on Ethereum Sepolia
        receiverCrossChainDex = new CrossChainDex(address(router), SEPOLIA_CHAIN_SELECTOR);
        console.log("ReceiverDex deployed to: ", address(receiverCrossChainDex));

        // Step 4) Allowlist Avalanche Fuji chain on ReceiverDex.sol (TODO: Check as to why this is making sense instead of FUJI_CHAIN_SELECTOR)
        receiverCrossChainDex.enableChain(FUJI_CHAIN_SELECTOR, address(senderCrossChainDex), "");
        console.log("allowlistSourceChain on receiverCrossChainDex executed succesfully");

        vm.makePersistent(address(senderCrossChainDex), address(receiverCrossChainDex)); // TODO: Uncomment this
    }

    function testSwapCrossChain() public {
        // Step 5) On Avalanche Fuji, call enableChain function
        vm.selectFork(ethSepoliaFork);
        uint256 balanceBeforeOnSepolia = IERC20(SEPOLIA_USDC_TOKEN).balanceOf(BOB);
        console.log("SEPOLIA_USDC_TOKEN balance of Bob: ", balanceBeforeOnSepolia);

        vm.selectFork(avaxFujiFork);
        uint256 balanceBeforeOnFuji = IERC20(FUJI_USDC_TOKEN).balanceOf(BOB);
        console.log("FUJI_USDC_TOKEN balance of Bob: ", balanceBeforeOnFuji);

        senderCrossChainDex.enableChain(SEPOLIA_CHAIN_SELECTOR, address(receiverCrossChainDex), "");

        // On Avalanche Fuji, call approve and transferUsdc function to receiverCrossChainDex
        uint256 amount = 1000_000;
        // vm.prank(BOB);
        // IERC20(FUJI_USDC_TOKEN).transfer(address(senderCrossChainDex), amount);
        // console.log("FUJI_USDC_TOKEN balance of address(senderCrossChainDex): ", IERC20(FUJI_USDC_TOKEN).balanceOf(address(senderCrossChainDex)));

        uint256 gasFee = senderCrossChainDex.getGasFee(
            address(senderCrossChainDex),
            address(receiverCrossChainDex),
            FUJI_USDC_TOKEN,
            amount,
            SEPOLIA_USDC_TOKEN,
            amount,
            1,
            SEPOLIA_CHAIN_SELECTOR
        );
        console.log("Gas fee required for ccipSend: ", gasFee);
        uint64 gasLimit = 500_000; // TODO: Add extraArgs param that is required
        uint64 fee = .1 ether; // TODO: Calculate the exact gas fee required to be passed as the msg.value
        vm.prank(BOB);
        senderCrossChainDex.ccipSend{value: fee}(
            address(senderCrossChainDex),
            address(receiverCrossChainDex),
            FUJI_USDC_TOKEN,
            amount,
            SEPOLIA_USDC_TOKEN,
            amount,
            1,
            SEPOLIA_CHAIN_SELECTOR
        );
        vm.stopPrank();

        // Step 6) On Ethereum Sepolia, check if USDC was succesfully transferred
        // Get user's USDC balance on both chains before and after transfer
        uint256 balanceAfterOnFuji = IERC20(FUJI_USDC_TOKEN).balanceOf(BOB);

        ccipLocalSimulatorFork.switchChainAndRouteMessage(ethSepoliaFork);
        uint256 balanceAfterOnSepolia = IERC20(SEPOLIA_USDC_TOKEN).balanceOf(address(receiverCrossChainDex));
        // uint256 cUsdcBalanceOfCrossChainReceiver = IERC20(COMET).balanceOf(address(receiverCrossChainDex));
        console.log("Balance after on sepolia: ", balanceAfterOnSepolia);

        // Check if USDC was transferred
        assertEq(balanceAfterOnFuji, balanceBeforeOnFuji - amount);
        // assertEq compound usdc token balance of receiverCrossChainDex
    }

}