// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console, Vm} from "forge-std/Test.sol";
import {CrossChainDex} from "../src/CrossChainDex.sol";
import {ReceiverDex} from "../src/ReceiverDex.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {MockCCIPRouter} from "@chainlink/contracts-ccip/src/v0.8/ccip/test/mocks/MockRouter.sol";

contract CrossChainDexTest is Test {
    
    address private constant BOB = 0x47D1111fEC887a7BEb7839bBf0E1b3d215669D86;
    // Avalanche Fuji Testnet constants
    uint64 private constant FUJI_CHAIN_SELECTOR = 14767482510784806043;
    address private constant FUJI_USDC_TOKEN = 0x5425890298aed601595a70AB815c96711a31Bc65;
    address private constant FUJI_LINK_TOKEN = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;
    uint256 private constant AMOUNT = 1000_000;

    // Ethereum Sepolia Testnet constants
    uint64 private constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    address private constant SEPOLIA_USDC_TOKEN = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    CrossChainDex private senderCrossChainDex;
    // SwapTestnetUSDC private swapTestnetUSDC;
    ReceiverDex private receiverCrossChainDex;
    CCIPLocalSimulatorFork private ccipLocalSimulatorFork;
    MockCCIPRouter private router;

    uint256 avaxFujiFork;
    uint256 ethSepoliaFork;

    function setUp() public {
        
        string memory AVALANCHE_FUJI_RPC_URL = vm.envString("AVALANCHE_FUJI_RPC_URL");
        string memory ETHEREUM_SEPOLIA_RPC_URL = vm.envString("ETHEREUM_SEPOLIA_RPC_URL");
        avaxFujiFork = vm.createSelectFork(AVALANCHE_FUJI_RPC_URL);
        ethSepoliaFork = vm.createFork(ETHEREUM_SEPOLIA_RPC_URL);

        vm.prank(BOB);
        IERC20(FUJI_USDC_TOKEN).transfer(address(this), AMOUNT);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        router = new MockCCIPRouter();
        vm.makePersistent(address(ccipLocalSimulatorFork), address(router));

        // Step 1) Deploy CrossChainDex.sol to Avalanche Fuji
        assertEq(vm.activeFork(), avaxFujiFork);

        senderCrossChainDex = new CrossChainDex(address(router), FUJI_CHAIN_SELECTOR);
        console.log("CrossChainDex deployed to: ", address(senderCrossChainDex));
        // vm.deal(address(senderCrossChainDex), 1 ether); // Note: The deployed contract should be funded with ether at the time of calling the function
        // senderCrossChainDex.enableChain(SEPOLIA_CHAIN_SELECTOR, address(receiverCrossChainDex), "");
        IERC20(FUJI_USDC_TOKEN).approve(address(senderCrossChainDex), AMOUNT);

        // vm.prank(BOB);
        // IERC20(FUJI_LINK_TOKEN).transfer(address(senderCrossChainDex), 3 ether);

        // Step 2) Deploy SwapTestnetUSDC.sol on Ethereum Sepolia
        vm.selectFork(ethSepoliaFork);
        assertEq(vm.activeFork(), ethSepoliaFork);

        // swapTestnetUSDC = new SwapTestnetUSDC(SEPOLIA_USDC_TOKEN, COMPOUND_USDC_TOKEN, FAUCETEER);
        // console.log("SwapTestnetUSDC deployed to: ", address(swapTestnetUSDC));

        // Step 3) Deploy ReceiverDex.sol on Ethereum Sepolia
        receiverCrossChainDex = new ReceiverDex(address(router), SEPOLIA_CHAIN_SELECTOR);
        console.log("ReceiverDex deployed to: ", address(receiverCrossChainDex));

        // Step 4) Allowlist Avalanche Fuji chain on ReceiverDex.sol (TODO: Check as to why this is making sense instead of FUJI_CHAIN_SELECTOR)
        receiverCrossChainDex.allowlistSourceChain(SEPOLIA_CHAIN_SELECTOR, 1); // 1 to signify true (saves gas)
        console.log("allowlistSourceChain on receiverCrossChainDex executed succesfully");

        // Step 5) Allowlist sender CrossChainDex on ReceiverDex.sol
        // receiverCrossChainDex.allowlistSender(address(senderCrossChainDex), true); // TODO: Add this function in the receiver if necessary

        // vm.makePersistent(address(senderCrossChainDex), address(receiverCrossChainDex)); // TODO: Uncomment this
    }

    function testDepositCrossChain() public {
        // Step 4) On Avalanche Fuji, call enableChain function
        // vm.selectFork(ethSepoliaFork);
        // uint256 balanceBeforeOnSepolia = IERC20(SEPOLIA_USDC_TOKEN).balanceOf(BOB);

        vm.selectFork(avaxFujiFork);
        uint256 balanceBeforeOnFuji = IERC20(FUJI_USDC_TOKEN).balanceOf(BOB);
        console.log("FUJI_USDC_TOKEN balance of Bob: ", balanceBeforeOnFuji);

        senderCrossChainDex.enableChain(SEPOLIA_CHAIN_SELECTOR, address(receiverCrossChainDex), "");
        
        // Step 3) On Avalanche Fuji, fund CrossChainDex.sol with 3 LINK
        // ccipLocalSimulatorFork.requestLinkFromFaucet(address(senderCrossChainDex), 3 ether);

        // On Avalanche Fuji, call approve and transferUsdc function to receiverCrossChainDex
        uint256 amount = 1000_000;
        vm.prank(BOB);
        IERC20(FUJI_USDC_TOKEN).transfer(address(senderCrossChainDex), amount);
        console.log("FUJI_USDC_TOKEN balance of address(senderCrossChainDex): ", IERC20(FUJI_USDC_TOKEN).balanceOf(address(senderCrossChainDex)));

        uint64 gasLimit = 500_000;
        uint64 fee = .1 ether; // TODO: Calculate the exact gas fee required to be passed as the msg.value
        vm.prank(BOB);
        senderCrossChainDex.ccipSend{value: fee}(
            address(this),
            address(receiverCrossChainDex),
            FUJI_USDC_TOKEN,
            amount,
            SEPOLIA_USDC_TOKEN,
            amount,
            1,
            SEPOLIA_CHAIN_SELECTOR
        );
        vm.stopPrank();

        // Step 5) On Ethereum Sepolia, check if USDC was succesfully transferred
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