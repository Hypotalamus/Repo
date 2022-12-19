// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./ERC721.sol";
import "./ERC721Receiver.sol";

/// @title Non-Fungible Token representing shares
/// @author Mikhail Dymkov
/// @notice Contract is ERC721-compatible
contract SharesNFT is ERC721 {
    /********************
    * Types section
    ********************/
    struct Share {
        string company;
        uint256 amount;
        bool repo_participating;
    }

    /********************* 
    * State section 
    *********************/

    // contract's owner
    address public contractOwner = msg.sender;

    // mapping from owner's address to token count
    mapping(address => uint) internal _balanceOf;

    // mapping from token's id to owner's address
    mapping(uint => address) internal _ownerOf;

    // mapping from token's owner to operator approvals
    // If true then operator can manage all owners' tokens
    // (<owner's address> => (<operator's address> => <approval>))
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    // mapping from token to address of token's authorized operator
    mapping(uint => address) internal _approvals;

    // mapping from token to information about appropriate share
    mapping(uint => Share) public _shares; 

    /*********************
    * Errors section
    *********************/

    /// 0x0 address as input parameter was detected
    error ZeroAddressDetected();

    /// Nonexistent token was queried
    error TokenDoesNotExist(uint256 _tokenId);

    /// Operator has no suficcient rights for requested operation 
    error InsuficcientRights(uint256 _tokenId, address _operator);

    /// Address is not a token's owner
    error NotAnOwner(address _someAddr, uint256 _tokenId);

    /// Token transfered to unsafe recepient
    error UnsafeRecepient();

    /// Only contract owner authorized for operation
    error NotContractOwner(address _someAddr);

    /// Token with given id already minted
    error AlreadyMinted(uint256 _tokenId);

    /// There are restrictions on token usage when it participates in repo
    error RepoLocked(uint256 _tokenId);

    /// Could not close repo when it was not opened
    error NotInRepoParticipating(uint256 _tokenId);

    /// This is not address of repo contract (or any contract at all)
    error NotAContract(address _someAddr);

    /// Failed to transfer token to complete phase one of repo
    error FailedToCompleteRepoPhaseOne(address _repoContract, uint256 _tokenId);

    /*********************
    * Modifiers section
    ********************/

    // Check existance of token with id _tokenId
    modifier tokenExist(uint256 _tokenId) {
        address tokenOwner = _ownerOf[_tokenId];
        if (tokenOwner == (address)(0))
            revert TokenDoesNotExist(_tokenId);
        _;        
    }

    // Check whether address _addr is zero or not
    modifier addressIsNotZero(address _addr) {
        if (_addr == (address)(0))
            revert ZeroAddressDetected();
        _;
    }

    // Only contract's owner can call some methods
    modifier onlyOwner() {
        if (msg.sender != contractOwner)
                revert NotContractOwner(msg.sender);
        _;
    }

    // Check whether token participates in repo or not
    modifier notParticipateInRepo(uint256 _tokenId) {
        bool repoIsActive = _shares[_tokenId].repo_participating;
        if (repoIsActive)
            revert RepoLocked(_tokenId);
        _;        
    }

    // Check whether address can tranfer token or assign grant
    modifier haveAuthority(uint256 _tokenId) {
        address tokenOwner = _ownerOf[_tokenId];
        if (msg.sender != tokenOwner && 
            !isApprovedForAll[tokenOwner][msg.sender] &&
            msg.sender != _approvals[_tokenId])
        {
            revert InsuficcientRights(_tokenId, msg.sender);
        }
        _;        
    } 

    /*********************
    * Methods section
    *********************/

    /* ERC721 methods' implementation */

    function balanceOf(address _owner) 
        external 
        view 
        addressIsNotZero(_owner) 
        returns (uint256) 
    {
        return _balanceOf[_owner];
    }

    function ownerOf(uint256 _tokenId) 
        external 
        view 
        tokenExist(_tokenId) 
        returns (address) 
    {
        return _ownerOf[_tokenId];
    }

    function safeTransferFrom(
        address _from, 
        address _to, 
        uint256 _tokenId, 
        bytes calldata data
    ) external payable {
        _transfer(_from, _to, _tokenId);
        if (_to.code.length > 0)
            _callReceiver(_to, _from, _tokenId, data);
    }

    function safeTransferFrom(
        address _from, 
        address _to, 
        uint256 _tokenId
    ) external payable {
        _transfer(_from, _to, _tokenId);
        if (_to.code.length > 0)
            _callReceiver(_to, _from, _tokenId);
    }

    function transferFrom(
        address _from, 
        address _to, 
        uint256 _tokenId
    ) external payable {
        _transfer(_from, _to, _tokenId);              
    }

    function approve(address _approved, uint256 _tokenId) 
        external 
        payable 
        tokenExist(_tokenId)
        haveAuthority(_tokenId)
        notParticipateInRepo(_tokenId)
    {
        address tokenOwner = _ownerOf[_tokenId];
        _approvals[_tokenId] = _approved;
        emit Approval(tokenOwner, _approved, _tokenId);         
    }

    function setApprovalForAll(address _operator, bool _approved) external {
        address owner = msg.sender;
        isApprovedForAll[owner][_operator] = _approved;        
        emit ApprovalForAll(owner, _operator, _approved);
    }

    function getApproved(uint256 _tokenId) 
        external 
        view 
        tokenExist(_tokenId)
        returns (address) 
    {
        return _approvals[_tokenId];                
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == type(ERC721).interfaceId ||
            interfaceID == type(ERC165).interfaceId;
    }

    /* Custom methods's implementation */

    /// @notice Mint new token
    /// @param _to address of new token's owner
    /// @param _tokenId id of new token (must not match identifiers of existant tokent)
    /// @param _company name of the issuing company
    /// @param _amount amount of shares providing new token 
    function mint(
        address _to, 
        uint256 _tokenId,
        string calldata _company,
        uint256 _amount
    ) 
        external
        onlyOwner 
        addressIsNotZero(_to) 
    {      
        if (_ownerOf[_tokenId] != address(0))
            revert AlreadyMinted(_tokenId);        

        _balanceOf[_to]++;
        _ownerOf[_tokenId] = _to;
        _shares[_tokenId] = Share({
            company: _company, 
            amount: _amount, 
            repo_participating: false
        });

        emit Transfer(address(0), _to, _tokenId);
    }

    /// @notice Change address of contract's owner
    /// @param _newOwner address of new owner
    function changeContractOwner(address _newOwner) 
        external
        onlyOwner 
        addressIsNotZero(_newOwner)
    {
        contractOwner = _newOwner;                
    }

    /// @notice Burn existant token. Only token's owner can do this if the token
    /// does not participate in repo.
    /// @param _tokenId id of burnt token
    function burn(uint256 _tokenId) 
        external 
        tokenExist(_tokenId)
        notParticipateInRepo(_tokenId) 
    {
        address owner = _ownerOf[_tokenId];
        if (msg.sender != owner)
            revert InsuficcientRights(_tokenId, msg.sender);

        _balanceOf[owner]--;
        delete _ownerOf[_tokenId];
        delete _approvals[_tokenId];
        delete _shares[_tokenId];

        emit Transfer(owner, address(0), _tokenId);
    }

    /// @notice Send token to Repo contract to close phase one of deal
    /// @param _repoContract address of Repo smart contract
    /// @param _tokenId id of token which will be transfered as collateral
    function participateInRepo(
        address _repoContract,
        uint256 _tokenId
    ) 
        external 
        tokenExist(_tokenId)
        haveAuthority(_tokenId)
        addressIsNotZero(_repoContract)
        notParticipateInRepo(_tokenId) 
    {
        if (_repoContract.code.length == 0)
            revert NotAContract(_repoContract);

        _approvals[_tokenId] = _repoContract;
        _shares[_tokenId].repo_participating = true;
    }

    /// @notice Get information whether token is participating in repo or not.
    /// @dev Method throws if token with _tokenId does not exist in storage.
    /// @param _tokenId Identifier of target token
    /// @return true if token participates in repo else false
    function getRepoStatus(uint256 _tokenId) 
        external 
        view 
        tokenExist(_tokenId)
        returns (bool) 
    {
        return _shares[_tokenId].repo_participating;                
    }

    /// @notice Close repo if it was opened. Should be called by Repo smart contract.
    /// @dev Throws if token does not exist, is not participating in repo now 
    ///  or if caller is not an approved smart contract
    /// @param _tokenId Identifier of token participating in repo
    function closeRepo(uint256 _tokenId) external tokenExist(_tokenId) {
        bool repo_status = _shares[_tokenId].repo_participating;
        if (!repo_status)
            revert NotInRepoParticipating(_tokenId);
        if (msg.sender != _approvals[_tokenId])
            revert InsuficcientRights(_tokenId, msg.sender);

        _shares[_tokenId].repo_participating = false;
        _approvals[_tokenId] = address(0);
    }

    /* Internal utility functions */

    /// @dev Transfer token from one address to another
    /// @param _from address of token's owner
    /// @param _to address of token's recepient
    /// @param _tokenId id of transferred token
    function _transfer(
        address _from, 
        address _to, 
        uint256 _tokenId
    ) 
        internal 
        tokenExist(_tokenId)
        haveAuthority(_tokenId)
        addressIsNotZero(_to) 
    {
        address tokenOwner = _ownerOf[_tokenId];      
        if (_from != tokenOwner)
            revert NotAnOwner(_from, _tokenId);

        bool repoIsActive = _shares[_tokenId].repo_participating;
        if (repoIsActive && msg.sender != _approvals[_tokenId])
            revert RepoLocked(_tokenId);       

        _balanceOf[_from]--;
        _ownerOf[_tokenId] = _to;
        _balanceOf[_to]++;

        if (!repoIsActive)
            delete _approvals[_tokenId];

        emit Transfer(_from, _to, _tokenId);               
    }

    /// @dev According to ERC721 if token receiver is smart contract it should
    ///  has onERC721Received() function. This function should be called after
    ///  token transfer.
    /// @param _receiver address of smart contract received token
    /// @param _sender address initiated transer
    /// @param _tokenId id of transferred token
    /// @param _data arguments for onERC721Received() packed in array of bytes
    function _callReceiver(
        address _receiver,
        address _sender,
        uint256 _tokenId,
        bytes calldata _data
    ) internal {
        bytes4 callResult = ERC721TokenReceiver(_receiver).onERC721Received(
            msg.sender, 
            _sender, 
            _tokenId, 
            _data
        );
        if (callResult != ERC721TokenReceiver.onERC721Received.selector)
            revert UnsafeRecepient();
    }

    /// @dev Overloaded version of previous function. Instead of _data
    ///  onERC721Received() get "" - empty string   
    function _callReceiver(
        address _receiver,
        address _sender,
        uint256 _tokenId
    ) internal {
        bytes4 callResult = ERC721TokenReceiver(_receiver).onERC721Received(
            msg.sender, 
            _sender, 
            _tokenId, 
            ""
        );
        if (callResult != ERC721TokenReceiver.onERC721Received.selector)
            revert UnsafeRecepient();
    }        
}