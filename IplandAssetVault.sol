// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./InterfaceIplandNft.sol";

contract AssetVault is
    Initializable,
    ReentrancyGuardUpgradeable,
    ERC721HolderUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    CountersUpgradeable.Counter private _aIdCounter;
    CountersUpgradeable.Counter private _vIdCounter;

    /// @dev startTwitterName => nft asset address => nft tokenId
    mapping(uint256 => Asset) public nftAssets;

    mapping(uint256 => VaultSlot) public vSlots;
    
    mapping(string => address) public tNameToWallet;

    address public iplandNft;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {}

    function initialize(address _nft) public validAddr(_nft) initializer {
        iplandNft = _nft;

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADER_ROLE, msg.sender);
        _aIdCounter.increment();
        _vIdCounter.increment();
    }

    enum vStatus {
        Empty,    /// 0
        Locked,   /// 1
        Burned,   /// 2
        Claimed,  /// 3
        Returned  /// 4
    }

    struct Asset {
        uint256 aId;
        string recipient;
        address nftAddr;
        uint256 tId;
        string oAuthor;
        string creator;
    }

    struct VaultSlot {
        uint256 vId;
        Asset asset;
        vStatus status;
        address sender;
    }

    error InvalidAddr(string info, address addr);

    modifier validAddr(address addr) {
        if (addr == address(0)) revert InvalidAddr("Invalid Addr", addr);
        _;
    }

    function getSlotInfo(uint256 aId) external view returns(
        string memory recipient,
        address nftAddr,
        uint256 tId,
        string memory oAuthor,
        string memory creator,
        uint256 status,
        address sender
    ){
        require(aId <= _aIdCounter.current(), "VAULT: ERR aID");
        VaultSlot storage v = vSlots[aId];
        Asset storage a = nftAssets[aId];
        
        recipient = a.recipient;
        nftAddr = a.nftAddr;
        tId = a.tId;
        oAuthor = a.oAuthor;
        creator = a.creator;
        status = uint256(v.status);
        sender = v.sender;
    }

    function getWallet(string memory name)external view returns(address account){
        account = tNameToWallet[name];
    }


    function setWallet(string memory tName, address account)
        external
        validAddr(account)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        tNameToWallet[tName] = account;
        emit LogSetWallet(tName, account);
    }

    event LogSetWallet(string tName, address account);

    /* @dev Deposit ipland nft721 asset to this vault
     *     directly call iplandNft and mint token to this contract
     */
    function depositIplandAsset(
        string memory _recipient,
        string memory _oAuthor,
        string memory _creator
    ) public nonReentrant {
        require(bytes(_recipient).length > 0, "VAULT: EMPTY RECIVIENT");
        require(bytes(_creator).length > 0, "VAULT: EMPTY RECIVIENT");

        uint256 aId = _aIdCounter.current();

        /// @dev call iplandNft to mint
        nftAssets[aId] = Asset(
            aId,
            _recipient,
            iplandNft,
            _tId,
            _oAuthor,
            _creator
        );

        vSlots[aId] = VaultSlot(
            aId,
            nftAssets[aId],
            vStatus.Locked,
            msg.sender
        );

        _aIdCounter.increment();
        /// log
        emit LogDepositAsset(
            aId,
            _recipient,
            iplandNft,
            _tId,
            _oAuthor,
            _creator,
            msg.sender
        );
    }

    /**
     * @dev Deposit nft721 asset to this vault
     *  Appove nft721 to this contract before invoke
     */
    function depositAsset(
        string memory _recipient,
        address _nftAddr,
        uint256 _tId,
        string memory _oAuthor,
        string memory _creator
    ) public nonReentrant validAddr(_nftAddr) {
        require(bytes(_recipient).length > 0, "VAULT: EMPTY RECIVIENT");
        require(bytes(_creator).length > 0, "VAULT: EMPTY RECIVIENT");
        uint256 aId = _aIdCounter.current();
        IERC721(_nftAddr).safeTransferFrom(msg.sender, address(this), _tId);
        nftAssets[aId] = Asset(
            aId,
            _recipient,
            _nftAddr,
            _tId,
            _oAuthor,
            _creator
        );

        vSlots[aId] = VaultSlot(
            aId,
            nftAssets[aId],
            vStatus.Locked,
            msg.sender
        );

        _aIdCounter.increment();
        /// log
        emit LogDepositAsset(
            aId,
            _recipient,
            _nftAddr,
            _tId,
            _oAuthor,
            _creator,
            msg.sender
        );
    }

    event LogDepositAsset(
        uint256 indexed aId,
        string recipient,
        address indexed nftAddr,
        uint256 tId,
        string oAuthor,
        string creator,
        address indexed sender
    );

    function signAsset(uint256 aId, uint256 opCode) public {
        require(aId <= _aIdCounter.current(), "VAULT: ERR aID");
        VaultSlot storage v = vSlots[aId];
        Asset storage a = nftAssets[aId];
        require(v.status == vStatus.Locked, "VAULT: ERR NO LOCKED");
        require(
            tNameToWallet[a.recipient] == msg.sender,
            "VAULT: ERR RECIPIENT"
        );

        // op 1 sign and got the nft
        if (opCode == 0) {
            IERC721(a.nftAddr).transferFrom(address(this), msg.sender, a.tId);
            v.status = vStatus.Claimed;
            emit LogSignAsset(aId, a.recipient, msg.sender, a.nftAddr, a.tId, opCode);
            return;
        }
    }

    event LogSignAsset(
        uint256 indexed aId,
        string recipient,
        address indexed account,
        address nftAddrs,
        uint256 tId,
        uint256 indexed opCode
    );

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // The following functions are overrides required by Solidity.

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155ReceiverUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
