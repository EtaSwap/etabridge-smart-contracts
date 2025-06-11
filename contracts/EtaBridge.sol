// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract EtaBridge is OApp, ReentrancyGuard {
    mapping(string => IERC20Metadata) public supportedTokens;
    uint16 public feeBasisPoints;
    uint256 private immutable scale = 1e18;
    uint16 private immutable maxFeeBasisPoints = 100; // 1%

    event TokensBridged(bytes32 indexed guid, address indexed sender, IERC20Metadata token, uint256 amount, address receiver, uint256 fee, uint32 targetChainId);
    event TokensReleased(bytes32 indexed guid, address indexed receiver, IERC20Metadata token, uint256 amount);
    event TokenAdded(string indexed symbol, IERC20Metadata indexed tokenAddress);
    event TokenRemoved(string indexed symbol);
    event FeeUpdated(uint16 indexed feeBasisPoints);

    error TokenNotSupported(string symbol);
    error FeeExceedMaximum(uint16 feeBasisPoints, uint16 maxFeeBasisPoints);
    error InvalidReceiverAddress();

    constructor(address _owner, address _lzEndpoint, uint16 _feeBasisPoints) Ownable(_owner) OApp(_lzEndpoint, _owner) {
        if (_feeBasisPoints > 100) revert FeeExceedMaximum(_feeBasisPoints, maxFeeBasisPoints);
        feeBasisPoints = _feeBasisPoints;
    }

    function addSupportedToken(string calldata _symbol, IERC20Metadata _address) external onlyOwner {
        supportedTokens[_symbol] = _address;
        emit TokenAdded(_symbol, _address);
    }

    function removeSupportedToken(string calldata _symbol) external onlyOwner {
        if (address(supportedTokens[_symbol]) == address(0)) revert TokenNotSupported(_symbol);
        delete supportedTokens[_symbol];
        emit TokenRemoved(_symbol);
    }

    function updateFee(uint16 _feeBasisPoints) external onlyOwner {
        if (_feeBasisPoints > 100) revert FeeExceedMaximum(_feeBasisPoints, maxFeeBasisPoints);
        feeBasisPoints = _feeBasisPoints;
        emit FeeUpdated(_feeBasisPoints);
    }

    function quote(
        string calldata symbol,
        uint256 amount,
        address receiver,
        uint32 targetChainId,
        bytes calldata _options
    ) public view returns (uint256 nativeFee) {
        if (receiver == address(0)) revert InvalidReceiverAddress();
        IERC20Metadata token = supportedTokens[symbol];
        if (address(token) == address(0)) revert TokenNotSupported(symbol);

        (uint256 amountAfterFee,) = _calculateAmountsToSend(token, amount);

        bytes memory payload = abi.encode(receiver, symbol, amountAfterFee);

        MessagingFee memory estimate = _quote(targetChainId, payload, _options, false);
        return estimate.nativeFee;
    }

    function bridgeTokens(
        string calldata symbol, 
        uint256 amount, 
        address receiver,
        uint32 targetChainId,
        bytes calldata _options
    ) external payable nonReentrant returns (MessagingReceipt memory receipt) {
        if (receiver == address(0)) revert InvalidReceiverAddress();
        IERC20Metadata token = supportedTokens[symbol];
        if (address(token) == address(0)) revert TokenNotSupported(symbol);

        uint256 transferredAmount = 0;
        {
            uint256 balanceBefore = token.balanceOf(address(this));
            SafeERC20.safeTransferFrom(token, msg.sender, address(this), amount);
            uint256 balanceAfter = token.balanceOf(address(this));
            transferredAmount = balanceAfter - balanceBefore;
        }

        (uint256 amountAfterFee, uint256 fee) = _calculateAmountsToSend(token, transferredAmount);

        bytes memory payload = abi.encode(receiver, symbol, amountAfterFee);

        receipt = _lzSend(targetChainId, payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
        emit TokensBridged(receipt.guid, msg.sender, token, amountAfterFee, receiver, fee, targetChainId);
    }

    function _calculateAmountsToSend(IERC20Metadata token, uint256 amount) private view returns (uint256 amountAfterFee, uint256 fee) {
        uint256 normalizedAmount = (amount * scale) / (10 ** token.decimals());
        fee = (normalizedAmount * feeBasisPoints) / 10000;
        amountAfterFee = normalizedAmount - fee;
    }

    function _lzReceive(
        Origin calldata,
        bytes32 guid,
        bytes calldata payload,
        address,
        bytes calldata
    ) internal override nonReentrant {
        (address receiver, string memory symbol, uint256 amount) = abi.decode(payload, (address, string, uint256));

        IERC20Metadata token = supportedTokens[symbol];
        if (address(token) == address(0)) revert TokenNotSupported(symbol);

        uint256 normalizedAmount = (amount * (10 ** token.decimals())) / scale;
        emit TokensReleased(guid, receiver, token, normalizedAmount);
        SafeERC20.safeTransfer(token, receiver, normalizedAmount);
    }

    // Recover ERC20 tokens sent to this contract
    function recoverERC20(IERC20 tokenAddress, uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(tokenAddress, owner(), amount);
    }

    // Recover native currency sent to this contract via specific functions
    function recoverNative() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
