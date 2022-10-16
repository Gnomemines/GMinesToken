// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.13;

import "./ERC20.sol";

import "./IPancake.sol";
import "./GasHelper.sol";
import "./SwapHelper.sol";

contract GnomeMinesCoin is GasHelper, ERC20 {
  address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
  address private constant ZERO = 0x0000000000000000000000000000000000000000;
  address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // BSC WBNB

  string private constant _nameToken = "GnomeMines Coin";
  string private constant _symbolToken = "GGCOIN";

  string public constant url = "www.gnomemines.com";
  string public constant author = "Lameni";

  // Token Details
  uint8 private constant decimal = 18;
  uint private constant maxSupply = 10_000_000 * (10**decimal);

  // Wallets limits
  uint public _maxTxAmount = maxSupply;
  uint public _maxAccountAmount = maxSupply;
  uint public _minAmountToAutoSwap = 1000 * (10**decimal); // 1000

  // Fees
  uint public feeAdministrationWallet = 500; // 5%

  uint private constant maxTotalFee = 1000;
  mapping(address => uint) public specialFeesByWallet;

  // Helpers
  bool internal pausedToken = false;
  bool private _noReentrance = false;

  bool public pausedSwapAdmin = false;

  // Counters
  uint public accumulatedToAdmin;

  // Liquidity Pair
  address public liquidityPool;

  // Wallets
  address public administrationWallet;
  address public swapHelperAddress;

  struct Receivers {
    address wallet;
    uint amount;
  }

  receive() external payable {}

  constructor() ERC20(_nameToken, _symbolToken) {
    PancakeRouter router = PancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); // BSC
    liquidityPool = address(PancakeFactory(router.factory()).createPair(WBNB, address(this)));

    administrationWallet = _msgSender();
    _permissions[administrationWallet] = 15;

    uint baseAttributes = 0;
    baseAttributes = setExemptAmountLimit(baseAttributes, true);
    _attributeMap[liquidityPool] = baseAttributes;

    baseAttributes = setExemptTxLimit(baseAttributes, true);
    _attributeMap[DEAD] = baseAttributes;
    _attributeMap[ZERO] = baseAttributes;

    baseAttributes = setExemptFee(baseAttributes, true);
    baseAttributes = setExemptSwapMaker(baseAttributes, true);
    _attributeMap[address(this)] = baseAttributes;

    baseAttributes = setExemptOperatePausedToken(baseAttributes, true);
    _attributeMap[_msgSender()] = baseAttributes;

    SwapHelper swapHelper = new SwapHelper();
    swapHelper.safeApprove(WBNB, address(this), type(uint).max);
    swapHelper.transferOwnership(_msgSender());
    swapHelperAddress = address(swapHelper);

    baseAttributes = setExemptOperatePausedToken(baseAttributes, false);
    _attributeMap[swapHelperAddress] = baseAttributes;

    _mint(_msgSender(), maxSupply);

    pausedToken = true;
  }

  // ----------------- Public Views -----------------
  function name() public pure override returns (string memory) {
    return _nameToken;
  }

  function symbol() public pure override returns (string memory) {
    return _symbolToken;
  }

  function getOwner() external view returns (address) {
    return owner();
  }

  function decimals() public pure override returns (uint8) {
    return decimal;
  }

  function getFeeTotal() public view returns (uint) {
    return feeAdministrationWallet;
  }

  function getSpecialWalletFee(address target) public view returns (uint adminFee) {
    adminFee = specialFeesByWallet[target];
  }

  // ----------------- Authorized Methods -----------------

  function enableToken() external isAdmin {
    pausedToken = false;
  }

  function setLiquidityPool(address newPair) external isAdmin {
    require(newPair != address(0), "invalid new pair address");
    liquidityPool = newPair;
  }

  function setPausedSwapAdmin(bool state) external isAdmin {
    pausedSwapAdmin = state;
  }

  // ----------------- Wallets Settings -----------------
  function setAdministrationWallet(address account) public isAdmin {
    require(account != address(0), "adminWallet cannot be Zero");
    administrationWallet = account;
  }

  // ----------------- Fee Settings -----------------
  function setFeesOperational(uint administration) external isFinancial {
    feeAdministrationWallet = administration;
    require(getFeeTotal() <= maxTotalFee, "All rates and fee together must be equal or lower than 10%");
  }

  function setSpecialWalletFee(address target, uint adminFee) external isFinancial {
    require(adminFee <= maxTotalFee, "All rates and fee together must be equal or lower than 10%");
    specialFeesByWallet[target] = adminFee;
  }

  // ----------------- Token Flow Settings -----------------
  function setMaxTxAmount(uint maxTxAmount) public isFinancial {
    require(maxTxAmount >= maxSupply / 10000, "Amount must be bigger then 0.01% tokens"); // 10000 tokens
    _maxTxAmount = maxTxAmount;
  }

  function setMaxAccountAmount(uint maxAccountAmount) public isFinancial {
    require(maxAccountAmount >= maxSupply / 10000, "Amount must be bigger then 0.01% tokens"); // 10000 tokens
    _maxAccountAmount = maxAccountAmount;
  }

  function setMinAmountToAutoSwap(uint amount) public isFinancial {
    _minAmountToAutoSwap = amount;
  }

  // ----------------- Special Authorized Operations -----------------
  function buyBackAndHoldWithDecimals(uint decimalAmount, address receiver) public isController {
    buyBackWithDecimals(decimalAmount, receiver);
  }

  function buyBackAndBurnWithDecimals(uint decimalAmount) public isController {
    buyBackWithDecimals(decimalAmount, address(0));
  }

  // ----------------- External Methods -----------------
  function burn(uint amount) external {
    _burn(_msgSender(), amount);
  }

  function multiTransfer(Receivers[] memory users) external {
    for (uint i = 0; i < users.length; i++) transfer(users[i].wallet, users[i].amount);
  }

  // ----------------- Internal CORE -----------------
  function _transfer(
    address sender,
    address receiver,
    uint amount
  ) internal override {
    require(amount > 0, "Invalid Amount");
    require(!_noReentrance, "ReentranceGuard Alert");
    _noReentrance = true;

    uint senderAttributes = _attributeMap[sender];
    uint receiverAttributes = _attributeMap[receiver];
    // Initial Checks
    require(sender != address(0) && receiver != address(0), "transfer from the zero address");
    require(!pausedToken || isExemptOperatePausedToken(senderAttributes), "Token is paused");
    require(amount <= _maxTxAmount || isExemptTxLimit(senderAttributes), "Exceeded the maximum transaction limit");

    uint senderBalance = _balances[sender];
    require(senderBalance >= amount, "Transfer amount exceeds your balance");
    uint newSenderBalance = senderBalance - amount;
    _balances[sender] = newSenderBalance;

    uint adminFee = feeAdministrationWallet;

    // Calculate Fees
    uint feeAmount = 0;
    if (!isExemptFee(senderAttributes) && !isExemptFeeReceiver(receiverAttributes)) {
      if (isSpecialFeeWallet(senderAttributes)) {
        // Check special wallet fee on sender
        adminFee = getSpecialWalletFee(sender);
      } else if (isSpecialFeeWalletReceiver(receiverAttributes)) {
        // Check special wallet fee on receiver
        adminFee = getSpecialWalletFee(receiver);
      }
      feeAmount = (adminFee * amount) / 10000;
    }

    if (feeAmount != 0) splitFee(feeAmount, sender, adminFee);
    if ((!pausedSwapAdmin) && !isExemptSwapMaker(senderAttributes)) autoSwap(sender, adminFee);

    // Update Recipient Balance
    uint newRecipientBalance = _balances[receiver] + (amount - feeAmount);
    _balances[receiver] = newRecipientBalance;
    require(newRecipientBalance <= _maxAccountAmount || isExemptAmountLimit(receiverAttributes), "Exceeded the maximum tokens an wallet can hold");

    _noReentrance = false;
    emit Transfer(sender, receiver, amount);
  }

  function autoSwap(address sender, uint adminFee) private {
    // --------------------- Execute Auto Swap -------------------------
    address liquidityPair = liquidityPool;
    if (sender == liquidityPair) return;

    uint adminAmount = accumulatedToAdmin;
    uint totalAmount = adminAmount;
    if (totalAmount < _minAmountToAutoSwap) return;

    // Execute auto swap
    address wbnbAddress = WBNB;
    address swapHelper = swapHelperAddress;

    (uint112 reserve0, uint112 reserve1) = getTokenReserves(liquidityPair);
    bool reversed = isReversed(liquidityPair, wbnbAddress);
    if (reversed) {
      uint112 temp = reserve0;
      reserve0 = reserve1;
      reserve1 = temp;
    }
    _balances[liquidityPair] += totalAmount;

    uint wbnbBalanceBefore = getTokenBalanceOf(wbnbAddress, swapHelper);
    uint wbnbAmount = getAmountOut(totalAmount, reserve1, reserve0);
    swapToken(liquidityPair, reversed ? 0 : wbnbAmount, reversed ? wbnbAmount : 0, swapHelper);
    uint wbnbBalanceNew = getTokenBalanceOf(wbnbAddress, swapHelper);
    require(wbnbBalanceNew == wbnbBalanceBefore + wbnbAmount, "Wrong amount of swapped on WBNB");

    // --------------------- Transfer Swapped Amount -------------------------
    if (adminAmount > 0 && adminFee > 0) {
      // Cost 2 cents
      uint amountToSend = wbnbBalanceNew;
      tokenTransferFrom(wbnbAddress, swapHelper, administrationWallet, amountToSend);
    }
    accumulatedToAdmin = 0;
  }

  function splitFee(
    uint incomingFeeTokenAmount,
    address sender,
    uint adminFee
  ) private {
    uint totalFee = adminFee;

    // Administrative distribution
    if (adminFee > 0) {
      accumulatedToAdmin += (incomingFeeTokenAmount * adminFee) / totalFee;
      if (pausedSwapAdmin) {
        address wallet = administrationWallet;
        uint walletBalance = _balances[wallet] + accumulatedToAdmin;
        _balances[wallet] = walletBalance;
        emit Transfer(sender, wallet, accumulatedToAdmin);
        accumulatedToAdmin = 0;
      }
    }
  }

  // --------------------- Private Methods -------------------------

  function buyBackWithDecimals(uint decimalAmount, address destAddress) private {
    uint maxBalance = getTokenBalanceOf(WBNB, address(this));
    if (maxBalance < decimalAmount) revert("insufficient WBNB amount on contract");

    address liquidityPair = liquidityPool;
    uint liquidityAttribute = _attributeMap[liquidityPair];

    uint newAttributes = setExemptTxLimit(liquidityAttribute, true);
    newAttributes = setExemptFee(liquidityAttribute, true);
    _attributeMap[liquidityPair] = newAttributes;

    address helperAddress = swapHelperAddress;

    (uint112 reserve0, uint112 reserve1) = getTokenReserves(liquidityPair);
    bool reversed = isReversed(liquidityPair, WBNB);
    if (reversed) {
      uint112 temp = reserve0;
      reserve0 = reserve1;
      reserve1 = temp;
    }

    tokenTransfer(WBNB, liquidityPair, decimalAmount);

    uint tokenAmount = getAmountOut(decimalAmount, reserve0, reserve1);
    if (destAddress == address(0)) {
      swapToken(liquidityPair, reversed ? tokenAmount : 0, reversed ? 0 : tokenAmount, helperAddress);
      _burn(helperAddress, tokenAmount);
    } else {
      swapToken(liquidityPair, reversed ? tokenAmount : 0, reversed ? 0 : tokenAmount, destAddress);
    }
    _attributeMap[liquidityPair] = liquidityAttribute;
  }
}