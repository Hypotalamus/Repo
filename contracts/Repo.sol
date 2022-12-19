// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./ERC721.sol";
import "./SharesNFT.sol";


/// @title Repo
/// @author Mikhail Dymkov
/// @notice Repo, repurchase agreement, is the loan of ethers secured by shares
///  which represented by token from SharesNFT smart contract.

interface IRepo {
    /// @dev This emits when repo's state changes. 
    event RepoStateChanged(uint256 indexed _newState);

    /// @dev Emits just before contract will be destroyed by calling selfdestruct()
    event RepoWillBeDestroyed();

    /// @dev Emits when lender transfer his rights to refund money on phase two of deal
    event LenderRigthsTransferred(address indexed _newLender);

    /// @notice Change timeout parameter in PhaseXOpened state.
    ///  If timeout occurs then deal will go to RepoHalted forever. Default value is
    ///  one day.
    /// @dev Only contract's owner can called this function and only in Init state.
    /// @param _newTimeout Value of new timeout period.
    function changeTimeout(uint256 _newTimeout) external;

    /// @notice Check if timeout occured or not. On phase one lender waits for shares 
    ///  after sending ethers to contract. He should periodically call this function.
    ///  If timeout occurs he refunds his money and repo will be halted. On the other hand,
    ///  on phase two lender waits for payback. He should periodically call this function.
    ///  At first lender waits for openning phase two. On timeout phase two is opened. Next
    ///  if timeout occurs again repo will be halted and he will get permanent rights on 
    ///  collateral.
    /// @dev Function returns value only if deal is in PhaseOneOpened, PhaseOneCompleted or 
    ///  PhaseTwoOpened state. Else it throws error and report current state. State machine 
    ///  updates by calling checkTimeout() in this states.
    /// @return true if timeout occured else false 
    function checkTimeout() external returns (bool);

    /// @notice After lender sends his money to contract on phase one, borrower must give 
    ///  his token to repo. He must call participateInRepo() in SharesNFT contract and then
    ///  confirm it by calling closePhaseOne(). After that repo state will be changed from
    ///  PhaseOneOpened to PhaseOneCompleted.
    ///  @return true if state was changed else false
    function closePhaseOne() external returns (bool);

    /// @notice Lender can transfer his rights to another address on PhaseOneCompleted state.
    function transmitLenderRights(address _newLender) external;

    /// @notice Get current state of repo deal
    /// @return 0 - Init, 1 - PhaseOneOpened, 2 - PhaseOneCompleted, 3 - PhaseTwoOpened,
    ///  4 - PhaseTwoCompleted, 5 - RepoHalted
    function getCurrentState() external view returns (uint256);

    /// @notice Destroy contract. Only owner can call this method and only when state is
    ///  Init, PhaseTwoCompleted or RepoHalted. 
    function destroy() external;
}

contract Repo is IRepo {

    /*******************
    * Types section
    *******************/

    enum RepoState {
        Init,
        PhaseOneOpened,
        PhaseOneCompleted,
        PhaseTwoOpened,
        PhaseTwoCompleted,
        RepoHalted
    }

    /*******************
    * State section
    *******************/

    // Address of contract's owner
    address payable immutable public contractOwner;

    // Address of smart contract released shares
    address immutable public sharesAddress;

    // Address of lender
    address payable public lenderAddress;

    // Identifier of collateral token
    uint256 immutable public tokenId;

    // Amount of wei that lender should issue to borrower
    uint256 immutable public loan;

    // Amount of wei that borrower should return. loan + commision
    uint256 immutable public refund;

    // Period between closing of phase one and openning of phase two
    uint256 immutable public dealTime;

    // Deal will be cancelled if timeout will be reached. By default it
    // has value of 1 days, but can be changed by contract's owner on the 
    // initial stage Init (0).
    uint256 public timeout = 1 days;

    // auxiliary variable to define whether timeout has come or not
    uint256 internal _timeBase;

    // internal state of repo contract
    RepoState internal _state;

    /*******************
    * Errors section
    *******************/

    /// 0x0 address as input parameter was detected
    error ZeroAddressDetected();

    /// Smart contract is not compatible with ERC721 standard
    error ERC721notSupported(address _addr);

    /// You are not an owner of presented token
    error NotTokenOwner(address _tokenAddr, uint256 _tokenId);

    /// You are not an owner of this contract
    error NotContractOwner();

    /// Only current lender can transfer his rights
    error LenderOnly();

    /*******************
    * Modifiers section
    *******************/

    // Check whether address _addr is zero or not
    modifier addressIsNotZero(address _addr) {
        if (_addr == (address)(0))
            revert ZeroAddressDetected();
        _;
    }

    // Check whether smart contract is ERC721 compatible or not
    modifier ERC721interfaceRequired(address _addr) {
        SharesNFT tokenContract = SharesNFT(_addr);
        bool ERC721supported = tokenContract.supportsInterface(type(ERC721).interfaceId);
        if (!ERC721supported)
            revert ERC721notSupported(_addr);
        _;        
    }

    // Check whether token belongs to message sender or not
    modifier tokenOwnerOnly(address _tokenAddr, uint256 _tokenId) {
        SharesNFT tokenContract = SharesNFT(_tokenAddr);
        address tokenOwner = tokenContract.ownerOf(_tokenId);
        if (msg.sender != tokenOwner)
            revert NotTokenOwner(_tokenAddr, _tokenId);                
        _;
    }

    // Check whether message sender is contract owner or not
    modifier contractOwnerOnly() {
        if (msg.sender != contractOwner)
            revert NotContractOwner();
        _;
    }

    // Check whether message sender is lender or not
    modifier lenderOnly {
        if (msg.sender != lenderAddress)
            revert LenderOnly();
        _;
    }

    /*******************
    * Methods section
    *******************/
    /// @notice The contract is deployed by the shares' holder. Preliminary 
    ///  he should tokenize shares by using special smart contract. He also 
    ///  become contract's owner. Only period between phases is set in constructor.
    ///  Other time parameters have default values but could be change before the 
    ///  lender will transfer currency on account.
    /// @param _sharesAddress The address of smart contract released token.
    ///  Contract is SharesNFT instance.
    /// @param _lenderAddress The address of lender.
    /// @param _tokenId Identifier of token in smart contract - SharesNFT instance.
    /// @param _loan Amount of wei that borrower wants for shares.
    /// @param _commission Additional amount of wei that borrower must return.
    ///  Overall amount that borrower must return is _loan + _commission
    /// @param _dealTime Period between closing phase one of deal and opening phase two.
    constructor(
        address _sharesAddress,
        address payable _lenderAddress,
        uint256 _tokenId,
        uint256 _loan,
        uint256 _commission,
        uint256 _dealTime        
    )
        addressIsNotZero(_sharesAddress)
        addressIsNotZero(_lenderAddress)
        ERC721interfaceRequired(_sharesAddress)
        tokenOwnerOnly(_sharesAddress, _tokenId) 
    {
        contractOwner = payable(msg.sender);
        sharesAddress = _sharesAddress;
        lenderAddress = payable(_lenderAddress);        
        tokenId = _tokenId;
        loan = _loan;
        refund = _loan + _commission;
        dealTime = _dealTime;
    }

    /// @notice In phase one lender should put loan ethers on balance to update state.
    ///  In phase two contract owner should put refund ethers on balance to update state.
    /// @dev Contract accepts money only being in Init (0) or PhaseTwoOpened (3) states.
    receive() external payable {
        require(_state == RepoState.Init || _state == RepoState.PhaseTwoOpened, 
            "Contract does not need money on this stage");

        if (_state == RepoState.Init && address(this).balance >= loan)
        {
            _state = RepoState.PhaseOneOpened;
            emit RepoStateChanged((uint256)(_state));
            _timeBase = block.timestamp;
            uint256 currRefund = address(this).balance - loan;
            if (currRefund > 0)
                payable(msg.sender).transfer(currRefund);
        } else if (_state == RepoState.PhaseTwoOpened && address(this).balance >= refund) {
            _state = RepoState.PhaseTwoCompleted;
            emit RepoStateChanged((uint256)(_state));
            // return shares to borrower...
            SharesNFT(sharesAddress).transferFrom(lenderAddress, contractOwner, tokenId);
            // ...close repo...
            SharesNFT(sharesAddress).closeRepo(tokenId);            
            // ...and redeem all ethers to legal parts           
            uint256 currRefund = address(this).balance - refund;
            if (currRefund > 0)
                payable(msg.sender).transfer(currRefund);
            lenderAddress.transfer(refund);
        }        
    }

    function changeTimeout(uint256 _newTimeout) 
        external
        contractOwnerOnly 
    {
        require(_state == RepoState.Init, "Timeout can be changed only in Init (0) state.");

        timeout = _newTimeout;
    }

    function checkTimeout() external returns (bool _success) {
        require(_state == RepoState.PhaseOneOpened ||
            _state == RepoState.PhaseOneCompleted ||
            _state == RepoState.PhaseTwoOpened, "Current stage has no time constraint.");

        _success = false;
        uint256 nowTime = block.timestamp;
        if (_state == RepoState.PhaseOneOpened && nowTime > _timeBase + timeout) {
            bool phaseOneIsClosed = closePhaseOne();
            if (!phaseOneIsClosed) {
                _state = RepoState.RepoHalted;
                emit RepoStateChanged((uint256)(_state));
                payable(lenderAddress).transfer(loan); 
                _success = true;
            } 
        } else if (_state == RepoState.PhaseOneCompleted && nowTime > _timeBase + dealTime) {
            _state = RepoState.PhaseTwoOpened;
            emit RepoStateChanged((uint256)(_state));
            _timeBase = nowTime;
            _success = true;
        } else if (_state == RepoState.PhaseTwoOpened && nowTime > _timeBase + timeout) {
            _state = RepoState.RepoHalted;
            emit RepoStateChanged((uint256)(_state));
            // get token to lender in permanent use by closing repo in current state
            SharesNFT(sharesAddress).closeRepo(tokenId);            
            _success = true;
        }
    }

    function closePhaseOne() public returns (bool) {
        require(_state == RepoState.PhaseOneOpened, "Contract is not in opened phase one");

        address tokenApproval = SharesNFT(sharesAddress).getApproved(tokenId);
        bool status = SharesNFT(sharesAddress).getRepoStatus(tokenId);
        if (tokenApproval == address(this) && status)
        {
            // Transfer shares to the lender...                      
            SharesNFT(sharesAddress).transferFrom(contractOwner, lenderAddress, tokenId);
            // ...transfer loan to borrower...
            payable(contractOwner).transfer(loan);
            // ...update timebase for timeout...
            _timeBase = block.timestamp;
            // ...and update state            
            _state = RepoState.PhaseOneCompleted;
            emit RepoStateChanged((uint256)(_state));
            return true;
        }
        else
        {
            return false;
        }
    }

    function transmitLenderRights(address _newLender) 
        external
        lenderOnly 
        addressIsNotZero(_newLender) 
    {
        require(_state == RepoState.PhaseOneCompleted, 
            "Rights can be transmited only when phase one was closed but phase two is not "
            "opened yet.");

        SharesNFT(sharesAddress).transferFrom(lenderAddress, _newLender, tokenId);
        lenderAddress = payable(_newLender);
        emit LenderRigthsTransferred(_newLender); 
    }

    function getCurrentState() external view returns (uint256 state) {
        state = (uint256)(_state);
    }

    function destroy() 
        external 
        contractOwnerOnly 
    {
        require(_state == RepoState.Init ||
            _state == RepoState.PhaseTwoCompleted || 
            _state == RepoState.RepoHalted, 
            "Contract can be destroyed only if it is in Init (0), PhaseTwoCompleted (4) "
            "or RepoHalted (5) state.");
        
        emit RepoWillBeDestroyed();
        selfdestruct(contractOwner);        
    }        
}