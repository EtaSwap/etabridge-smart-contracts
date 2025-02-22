// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract EtaBridge is Ownable, OApp, ReentrancyGuard {
    mapping(string => address) public supportedTokens;
    uint16 public feeBasisPoints;

    event TokensBridged(bytes32 indexed guid, address indexed sender, address token, uint256 amount, address receiver, uint256 fee, uint32 targetChainId);
    event TokensReleased(bytes32 indexed guid, address indexed receiver, address token, uint256 amount);
    event TokenAdded(string indexed symbol, address indexed tokenAddress);
    event TokenRemoved(string indexed symbol);

    constructor(address _owner, address _lzEndpoint, uint16 _feeBasisPoints) Ownable(_owner) OApp(_lzEndpoint, _owner) {
        feeBasisPoints = _feeBasisPoints;
    }

    function addSupportedToken(string calldata _symbol, address _address) external onlyOwner {
        supportedTokens[_symbol] = _address;
        emit TokenAdded(_symbol, _address);
    }

    function removeSupportedToken(string calldata _symbol) external onlyOwner {
        require(supportedTokens[_symbol] != address(0), "Token not supported");
        delete supportedTokens[_symbol];
        emit TokenRemoved(_symbol);
    }

    function updateFee(uint16 _feeBasisPoints) external onlyOwner {
        require(_feeBasisPoints <= 100, "Fee cannot exceed 1%");
        feeBasisPoints = _feeBasisPoints;
    }

    function quote(
        string calldata symbol,
        uint256 amount,
        address receiver,
        uint32 targetChainId,
        bytes calldata _options
    ) public view returns (uint256 nativeFee) {
        uint256 fee = (amount * feeBasisPoints) / 10000;
        uint256 amountAfterFee = amount - fee;

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
        require(receiver != address(0), "Invalid receiver address");
        require(supportedTokens[symbol] != address(0), "Token not supported");
        require(IERC20(supportedTokens[symbol]).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        uint256 fee = (amount * feeBasisPoints) / 10000;
        uint256 amountAfterFee = amount - fee;

        bytes memory payload = abi.encode(receiver, symbol, amountAfterFee);

        receipt = _lzSend(targetChainId, payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
        emit TokensBridged(receipt.guid, msg.sender, supportedTokens[symbol], amountAfterFee, receiver, fee, targetChainId);
    }

    function _lzReceive(
        Origin calldata,
        bytes32 guid,
        bytes calldata payload,
        address,
        bytes calldata
    ) internal override nonReentrant {
        (address receiver, string memory symbol, uint256 amount) = abi.decode(payload, (address, string, uint256));
        require(supportedTokens[symbol] != address(0), "Token not supported");

        emit TokensReleased(guid, receiver, supportedTokens[symbol], amount);
        require(IERC20(supportedTokens[symbol]).transfer(receiver, amount), "Token transfer failed");
    }

    // Recover ERC20 tokens sent to this contract
    function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(owner(), amount);
    }

    // Recover native currency sent to this contract via specific functions
    function recoverNative() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
