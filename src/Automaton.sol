/**
* SPDX-License-Identifier: LicenseRef-Aktionariat
*
* MIT License with Automated License Fee Payments
*
* Copyright (c) 2020 Aktionariat AG (aktionariat.com)
*
* Permission is hereby granted to any person obtaining a copy of this software
* and associated documentation files (the "Software"), to deal in the Software
* without restriction, including without limitation the rights to use, copy,
* modify, merge, publish, distribute, sublicense, and/or sell copies of the
* Software, and to permit persons to whom the Software is furnished to do so,
* subject to the following conditions:
*
* - The above copyright notice and this permission notice shall be included in
*   all copies or substantial portions of the Software.
* - All automated license fee payments integrated into this and related Software
*   are preserved.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/
pragma solidity >=0.6;

import "./SafeMath.sol";
import "./Ownable.sol";
import "./Pausable.sol";
import "./IERC20.sol";
import "./IUniswapV2.sol";

contract Automaton is Ownable, Pausable {

    using SafeMath for uint256;

    address public base;  // ERC-20 currency
    address public token; // ERC-20 share token

    address public copyright;
    uint8 public licenseFeeBps; // only charged on sales, max 1% i.e. 100

    uint256 private price; // current offer price, without drift
    uint256 public increment; // increment

    uint256 private driftStart;
    uint256 private timeToDrift; // seconds until drift pushes price by one increment
    bool private driftDirection;

    IUniswapV2 constant uniswap = IUniswapV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    event Transaction(address who, int amount, address token, uint totPrice, uint fee, address base, uint price);

    constructor(address baseCurrency, address shareToken) public {
        base = baseCurrency;
        token = shareToken;
        copyright = msg.sender;
        driftStart = block.timestamp;
        timeToDrift = 0;
    }

    function setPrice(uint256 newPrice, uint256 newIncrement) public onlyOwner {
        price = newPrice;
        increment = newIncrement;
        driftStart = block.timestamp;
    }

    function hasDrift() public view returns (bool) {
        return timeToDrift != 0;
    }

    // secondsPerStep should be negative for downwards drift
    function setDrift(uint256 secondsPerStep, bool upwards) public onlyOwner {
        setPrice(getPrice(), increment);
        timeToDrift = secondsPerStep;
        driftDirection = upwards;
    }

    function getPrice() public view returns (uint256) {
        return getPrice(block.timestamp);
    }

    function getPrice(uint256 timestamp) public view returns (uint256) {
        if (hasDrift()){
            uint256 passed = timestamp.sub(driftStart);
            uint256 drifted = (passed / timeToDrift).mul(increment);
            if (driftDirection){
                return price.add(drifted);
            } else if (drifted >= price){
                return 0;
            } else {
                return price - drifted;
            }
        } else {
            return price;
        }
    }

    function getPriceInEther(uint256 shares) public view returns (uint256) {
        uint256 totPrice = getBuyPrice(shares);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = base;
        return uniswap.getAmountsIn(totPrice, path)[0];
    }

    function buyWithEther(uint256 shares) public payable returns (uint256) {
        uint256 totPrice = getBuyPrice(shares);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = base;
        uint256[] memory amounts = uniswap.swapETHForExactTokens(totPrice, path, address(this), block.number);
        assert(totPrice == amounts[1]);
        _buy(msg.sender, msg.sender, shares, amounts[1]);
        uint256 contractEtherBalance = address(this).balance;
        if (contractEtherBalance > 0){
            msg.sender.transfer(contractEtherBalance);
        }
        return amounts[0];
    }

    function buy(uint256 numberOfSharesToBuy) public returns (uint256) {
        return buy(msg.sender, numberOfSharesToBuy);
    }

    function buy(address recipient, uint256 numberOfSharesToBuy) public returns (uint256) {
        return _buy(msg.sender, recipient, numberOfSharesToBuy, 0);
    }

    function _buy(address paying, address recipient, uint256 shares, uint256 alreadyPaid) internal returns (uint256) {
        uint256 totPrice = getBuyPrice(shares);
        IERC20 baseToken = IERC20(base);
        if (totPrice > alreadyPaid){
            require(baseToken.transferFrom(paying, address(this), totPrice - alreadyPaid));
        } else if (totPrice < alreadyPaid){
            // caller paid to much, return excess amount
            require(baseToken.transfer(paying, alreadyPaid - totPrice));
        }
        IERC20 shareToken = IERC20(token);
        require(shareToken.transfer(recipient, shares));
        price = price.add(shares.mul(increment));
        emit Transaction(paying, int256(shares), token, totPrice, 0, base, price);
        return totPrice;
    }

    function _notifyMoneyReceived(address from, uint256 amount) internal {
        uint shares = getShares(amount);
        _buy(from, from, shares, amount);
    }

    function sell(uint256 tokens) public returns (uint256){
        return sell(msg.sender, tokens);
    }

    function sell(address recipient, uint256 tokens) public returns (uint256){
        return _sell(msg.sender, recipient, tokens);
    }

    function _sell(address seller, address recipient, uint256 shares) internal returns (uint256) {
        IERC20 shareToken = IERC20(token);
        require(shareToken.transferFrom(seller, address(this), shares));
        return _notifyTokensReceived(recipient, shares);
    }

    // ERC-677 recipient
    function onTokenTransfer(address from, uint256 amount, bytes calldata /*data*/) public returns (bool success) {
        require(msg.sender == token || msg.sender == base);
        if (msg.sender == token){
            _notifyTokensReceived(from, amount);
        } else if (msg.sender == base){
            _notifyMoneyReceived(from, amount);
        } else {
            require(false);
        }
        return true;
    }

    function _notifyTokensReceived(address recipient, uint256 amount) internal returns (uint256){
        uint256 totPrice = getSellPrice(amount);
        IERC20 baseToken = IERC20(base);
        uint256 fee = getSaleFee(totPrice);
        if (fee > 0){
            require(baseToken.transfer(copyright, fee));
        }
        require(baseToken.transfer(recipient, totPrice - fee));
        price = price.sub(amount.mul(increment));
        emit Transaction(recipient, -int256(amount), token, totPrice, fee, base, price);
        return totPrice;
    }

    function getSaleFee(uint256 totalPrice) public view returns (uint256) {
        return totalPrice.mul(licenseFeeBps).div(10000);
    }

    function getSaleProceeds(uint256 shares) public view returns (uint256) {
        uint256 total = getSellPrice(shares);
        return total - getSaleFee(total);
    }

    function getSellPrice(uint256 shares) public view returns (uint256) {
        return getPrice(getPrice().sub(shares.mul(increment)), shares);
    }

    function getBuyPrice(uint256 shares) public view returns (uint256) {
        return getPrice(getPrice(), shares);
    }

    function getPrice(uint256 lowest, uint256 shares) internal view returns (uint256){
        require(shares >= 1);
        uint256 highest = lowest + (shares - 1).mul(increment);
        return (lowest.add(highest) / 2).mul(shares);
    }

    function getShares(uint256 money) public view returns (uint256) {
        return getShares(money, price);
    }

    function getShares(uint256 money, uint256 current) internal view returns (uint256) {
        if (money < current){
            return 0;
        } else {
            uint atleast = money / (current - 1);
            uint newPrice = current - atleast * increment;
            uint paid = getPrice(newPrice, atleast);
            return atleast + getShares(money - paid, newPrice);
        }
    }

    function setCopyright(address newOwner) public {
        require(msg.sender == copyright);
        copyright = newOwner;
    }

    function setLicenseFee(uint8 bps) public {
        require(msg.sender == copyright);
        require(bps < 100);
        licenseFeeBps = bps;
    }

    function withdraw(address ercAddress, address to, uint256 amount) public onlyOwner() {
        IERC20 erc20 = IERC20(ercAddress);
        require(erc20.transfer(to, amount), "Transfer failed");
    }

}