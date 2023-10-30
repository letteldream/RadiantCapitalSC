// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import "./layerzero/OFT.sol";
import "../dependencies/openzeppelin/contracts/Pausable.sol";

contract RadiantOFT is OFT, Pausable {
    using SafeMath for uint256;

    uint256 public immutable maxSupply;
    uint256 public immutable maxMintAmount;
    address public minter;
    bool private lpMintComplete = false;

    constructor(
        address _endpoint,
        uint256 _maxSupply,
        uint256 _maxMintAmount
    ) OFT("NOVA", "Supernova", _endpoint) {
        maxSupply = _maxSupply;
        maxMintAmount = _maxMintAmount;
        emit Transfer(address(0), msg.sender, 0);
    }

    // ERC20 stuff

    function setLpMintComplete() external {
        lpMintComplete = true;
    }

    function setMinter(address _minter) external returns (bool) {
        require(minter == address(0));
        minter = _minter;
        return true;
    }

    function burn(uint256 _value) external returns (bool) {
        _burn(msg.sender, _value);
        return true;
    }

    function mint(address _to, uint256 _value) external returns (bool) {
        require(msg.sender == minter || lpMintComplete == false, "No mint perm");
        _mint(_to, _value);
        return true;
    }

    function _mint(address account, uint256 amount) internal override {
        require(amount <= maxMintAmount);
        super._mint(account, amount);
        require(maxSupply >= totalSupply());
    }

    // Layzero stuff

    function bridge(uint256 amt, uint16 destChainId) external payable {
        _send(
            _msgSender(),
            destChainId,
            abi.encodePacked(_msgSender()),
            amt,
            _msgSender(),
            address(0),
            ""
        );
    }

    function _debitFrom(address _from, uint16 _dstChainId, bytes memory _toAddress, uint _amount) internal virtual override whenNotPaused {
        super._debitFrom(_from, _dstChainId, _toAddress, _amount);
    }

    function pauseBridge(bool pause) external onlyOwner {
        pause ? _pause() : _unpause();
    }
}