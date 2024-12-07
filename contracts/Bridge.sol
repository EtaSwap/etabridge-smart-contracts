// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract Bridge is Ownable, OApp {
    mapping(string => address) public supportedTokens;
    // mapping(uint16 => ChainConfig) public chainConfigs;
    uint16 public feeBasisPoints;

    event TokensBridged(address indexed sender, address indexed token, uint256 indexed amount, address receiver, uint256 fee, uint16 targetChainId);
    event TokensReleased(address indexed receiver, address indexed token, uint256 indexed amount);
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

    function bridgeTokens(
        string calldata symbol, 
        uint256 amount, 
        address receiver,
        uint16 targetChainId,
        bytes calldata _options
    ) external payable returns (MessagingReceipt memory receipt) {
        require(receiver != address(0), "Invalid receiver address");
        require(supportedTokens[symbol] != address(0), "Token not supported");
        require(IERC20(supportedTokens[symbol]).transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        uint256 fee = (amount * feeBasisPoints) / 10000;
        uint256 amountAfterFee = amount - fee;

        bytes memory payload = abi.encode(receiver, symbol, amountAfterFee);

        receipt = _lzSend(targetChainId, payload, _options, MessagingFee(msg.value, 0), payable(msg.sender));
        emit TokensBridged(msg.sender, supportedTokens[symbol], amountAfterFee, receiver, fee, targetChainId);
    }

    function _lzReceive(
        Origin calldata,
        bytes32,
        bytes calldata payload,
        address,
        bytes calldata
    ) internal override {
        (address receiver, string memory symbol, uint256 amount) = abi.decode(payload, (address, string, uint256));
        require(supportedTokens[symbol] != address(0), "Token not supported");
        require(IERC20(supportedTokens[symbol]).transfer(receiver, amount), "Token transfer failed");
        emit TokensReleased(receiver, supportedTokens[symbol], amount);
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
