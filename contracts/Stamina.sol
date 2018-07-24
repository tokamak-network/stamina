pragma solidity ^0.4.24;
pragma experimental ABIEncoderV2;


contract Stamina {
  // Withdrawal handles withdrawal request
  struct Withdrawal {
    uint128 amount;
    uint128 requestBlockNumber;
    address delegatee;
    bool processed;
  }

  /**
   * Internal States
   */
  // delegatee of `delegator` account
  // `delegator` => `delegatee`
  mapping (address => address) _delegatee;

  // stamina of delegatee
  // `delegatee` => `stamina`
  mapping (address => uint) _stamina;

  // total deposit of delegatee
  // `delegatee` => `total deposit`
  mapping (address => uint) _total_deposit;

  // deposit of delegatee
  // `depositor` => `delegatee` => `deposit`
  mapping (address => mapping (address => uint)) _deposit;

  // last recovery block of delegatee
  mapping (address => uint256) _last_recovery_block;

  // depositor => [index] => Withdrawal
  mapping (address => Withdrawal[]) _withdrawal;
  mapping (address => uint256) _last_processed_withdrawal;

  /**
   * Public States
   */
  bool public initialized;

  uint public MIN_DEPOSIT;
  uint public RECOVER_EPOCH_LENGTH; // stamina is recovered when block number % RECOVER_DELAY == 0
  uint public WITHDRAWAL_DELAY;     // Refund will be made WITHDRAWAL_DELAY blocks after depositor request Withdrawal.
                                    // WITHDRAWAL_DELAY prevents immediate withdrawal.
                                    // RECOVER_EPOCH_LENGTH * 2 < WITHDRAWAL_DELAY


  bool public development = true;   // if the contract is inserted directly into
                                    // genesis block, it will be false

  /**
   * Modifiers
   */
  modifier onlyChain() {
    require(development || msg.sender == address(0));
    _;
  }

  modifier onlyInitialized() {
    require(initialized);
    _;
  }

  /**
   * Events
   */
  event Deposited(address indexed depositor, address indexed delegatee, uint amount);
  event DelegateeChanged(address delegator, address oldDelegatee, address newDelegatee);
  event WithdrawalRequested(address indexed depositor, address indexed delegatee, uint amount, uint withdrawalIndex);
  event Withdrawan(address indexed depositor, address indexed delegatee, uint amount, uint withdrawalIndex);

  /**
   * Init
   */
  function init(uint minDeposit, uint recoveryEpochLength, uint withdrawalDelay) external {
    require(!initialized);

    require(minDeposit > 0);
    require(recoveryEpochLength > 0);
    require(withdrawalDelay > 0);

    require(recoveryEpochLength * 2 < withdrawalDelay);

    MIN_DEPOSIT = minDeposit;
    RECOVER_EPOCH_LENGTH = recoveryEpochLength;
    WITHDRAWAL_DELAY = withdrawalDelay;

    initialized = true;
  }

  /**
   * Getters
   */
  function getDelegatee(address delegator) public view returns (address) {
    return _delegatee[delegator];
  }

  function getStamina(address addr) public view returns (uint) {
    return _stamina[addr];
  }

  function getTotalDeposit(address delegatee) public view returns (uint) {
    return _total_deposit[delegatee];
  }

  function getDeposit(address depositor, address delegatee) public view returns (uint) {
    return _deposit[depositor][delegatee];
  }

  function getNumWithdrawals(address depositor) public view returns (uint) {
    return _withdrawal[depositor].length;
  }

  function getLastRecoveryBlock(address delegatee) public view returns (uint) {
    return _last_recovery_block[delegatee];
  }

  function getWithdrawal(address depositor, uint withdrawalIndex) public view returns (Withdrawal) {
    require(withdrawalIndex < getNumWithdrawals(depositor));
    return _withdrawal[depositor][withdrawalIndex];
  }

  /**
   * Setters
   */
  /// @notice Set `msg.sender` as delegatee of `delegator`
  function setDelegatee(address delegator)
    external
    onlyInitialized
    returns (bool)
  {
    address oldDelegatee = _delegatee[delegator];

    _delegatee[delegator] = msg.sender;

    emit DelegateeChanged(delegator, oldDelegatee, msg.sender);
    return true;
  }

  /**
   * Deposit / Withdraw
   */
  /// @notice Deposit Ether to delegatee
  function deposit(address delegatee)
    external
    payable
    onlyInitialized
    returns (bool)
  {
    require(msg.value >= MIN_DEPOSIT);

    uint lastBlock = _last_recovery_block[delegatee];

    uint totalDeposit = _total_deposit[delegatee];
    uint deposit = _deposit[msg.sender][delegatee];
    uint stamina = _stamina[delegatee];

    // check overflow
    require(totalDeposit + msg.value > totalDeposit);
    require(deposit + msg.value > deposit);
    require(stamina + msg.value > stamina);

    _total_deposit[delegatee] = totalDeposit + msg.value;
    _deposit[msg.sender][delegatee] = deposit + msg.value;
    _stamina[delegatee] = stamina + msg.value;

    if (lastBlock == 0) {
      lastBlock = block.number;
    }

    emit Deposited(msg.sender, delegatee, msg.value);
    return true;
  }

  /// @notice Request to withdraw deposit of delegatee. Ether can be withdrawn
  ///         after WITHDRAWAL_DELAY blocks
  function requestWithdrawal(address delegatee, uint amount)
    external
    onlyInitialized
    returns (bool)
  {
    require(amount > 0);

    uint totalDeposit = _total_deposit[delegatee];
    uint deposit = _deposit[msg.sender][delegatee];
    uint stamina = _stamina[delegatee];

    require(deposit > 0);

    // check underflow
    require(totalDeposit - amount < totalDeposit);
    require(deposit - amount < deposit); // this guarentees deposit >= amount

    _total_deposit[delegatee] = totalDeposit - amount;
    _deposit[msg.sender][delegatee] = deposit - amount;

    // NOTE: Is accepting the request right when stamina < amount?
    if (stamina > amount) {
      _stamina[delegatee] = stamina - amount;
    } else {
      _stamina[delegatee] = 0;
    }

    Withdrawal[] storage withdrawals = _withdrawal[msg.sender];

    uint withdrawalIndex = withdrawals.length;
    Withdrawal storage withdrawal = withdrawals[withdrawals.length++];

    withdrawal.amount = uint128(amount);
    withdrawal.requestBlockNumber = uint128(block.number);
    withdrawal.delegatee = delegatee;

    emit WithdrawalRequested(msg.sender, delegatee, amount, withdrawalIndex);
    return true;
  }

  /// @notice Process last unprocessed withdrawal request.
  function withdraw() external returns (bool) {
    Withdrawal[] storage withdrawals = _withdrawal[msg.sender];
    require(withdrawals.length > 0);

    uint lastWithdrawalIndex = _last_processed_withdrawal[msg.sender];
    uint withdrawalIndex;

    if (lastWithdrawalIndex == 0 && !withdrawals[0].processed) {
      withdrawalIndex = 0;
    } else if (lastWithdrawalIndex == 0) { // lastWithdrawalIndex == 0 && withdrawals[0].processed
      require(withdrawals.length >= 2);

      withdrawalIndex = 1;
    } else {
      withdrawalIndex = lastWithdrawalIndex + 1;
    }

    // double check out of index
    require(withdrawalIndex < withdrawals.length);

    Withdrawal storage withdrawal = _withdrawal[msg.sender][withdrawalIndex];

    // check withdrawal condition
    require(!withdrawal.processed);
    require(withdrawal.requestBlockNumber + WITHDRAWAL_DELAY <= block.number);

    uint amount = uint(withdrawal.amount);

    // withdrawal is processed
    withdrawal.processed = true;

    // mark processed withdrawal index
    _last_processed_withdrawal[msg.sender] = withdrawalIndex;

    // tranfser ether to depositor
    msg.sender.transfer(amount);
    emit Withdrawan(msg.sender, withdrawal.delegatee, amount, withdrawalIndex);

    return true;
  }

  /**
   * Stamina modification (only blockchain)
   * No event emitted during this functions.
   */
  /// @notice Add stamina of delegatee. The upper bound of stamina is total deposit of delegatee.
  ///         addStamina is called when remaining gas is refunded. So we can recover stamina
  ///         if RECOVER_EPOCH_LENGTH blocks are passed.
  ///
  ///         NOTE: can use block.number here?
  function addStamina(address delegatee, uint amount) external onlyChain returns (bool) {
    uint lastBlock = _last_recovery_block[delegatee];

    // if enough blocks has passed, recover whole used stamina.
    if (lastBlock + RECOVER_EPOCH_LENGTH >= block.number) {
      _stamina[delegatee] = _total_deposit[delegatee];
      _last_recovery_block[delegatee] = block.number;
      return true;
    }

    uint totalDeposit = _total_deposit[delegatee];
    uint stamina = _stamina[delegatee];

    require(stamina + amount > stamina);
    uint targetBalance = stamina + amount;

    if (targetBalance > totalDeposit) _stamina[delegatee] = totalDeposit;
    else _stamina[delegatee] = targetBalance;

    return true;
  }

  /// @notice Subtract stamina of delegatee.
  function subtractStamina(address delegatee, uint amount) external onlyChain returns (bool) {
    uint stamina = _stamina[delegatee];

    require(stamina - amount < stamina);
    _stamina[delegatee] = stamina - amount;
    return true;
  }
}
