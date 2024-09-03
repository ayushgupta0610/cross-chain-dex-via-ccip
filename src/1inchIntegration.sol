// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.0;

// import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";

// interface I1inch {
//     function swap(
//         address caller,
//         (address srcToken, address dstToken, address srcReceiver, address dstReceiver, uint256 amount, uint256 minReturnAmount, uint256 flags),
//         bytes calldata data
//     ) external payable returns (uint256 returnAmount, uint256 spentAmount);
// }

// contract OneInchSwap is Ownable {
//     using SafeERC20 for IERC20;

//     I1inch public immutable oneInch;
//     uint256 public constant MAX_INT = 2**256 - 1;

//     constructor(address _oneInchAddress) {
//         oneInch = I1inch(_oneInchAddress);
//     }

//     function swapTokens(
//         address tokenIn,
//         address tokenOut,
//         uint256 amountIn,
//         uint256 minAmountOut,
//         uint256 slippagePercentage,
//         bytes calldata data
//     ) external onlyOwner {
//         require(tokenIn != address(0) && tokenOut != address(0), "Invalid token addresses");
//         require(amountIn > 0, "Amount must be greater than 0");
//         require(slippagePercentage <= 100, "Slippage percentage must be <= 100");

//         IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
//         IERC20(tokenIn).safeApprove(address(oneInch), amountIn);

//         uint256 expectedAmountOut = minAmountOut;
//         uint256 actualMinAmountOut = expectedAmountOut * (100 - slippagePercentage) / 100;

//         (uint256 returnAmount, ) = oneInch.swap(
//             address(this),
//             (tokenIn, tokenOut, address(this), address(this), amountIn, actualMinAmountOut, 0),
//             data
//         );

//         require(returnAmount >= actualMinAmountOut, "Slippage limit exceeded");

//         IERC20(tokenOut).safeTransfer(msg.sender, returnAmount);

//         // Reset approval
//         IERC20(tokenIn).safeApprove(address(oneInch), 0);
//     }

//     function rescueTokens(address token, uint256 amount) external onlyOwner {
//         IERC20(token).safeTransfer(msg.sender, amount);
//     }

//     receive() external payable {}
// }