// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ILightVerifier.sol";
import "../periphery/WrappedAsset.sol";

contract LightVerifier is AccessControl, ILightVerifier {
    struct BlockConfirmationsInfo {
        uint256 count; // current oracle admin
        bool requireExtraCheck; // current oracle admin
        mapping(bytes32 => bool) isConfirmed; // submission => was confirmed
    }

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE"); // role allowed to submit the data
    uint256 public confirmationThreshold; // bonus reward for one submission
    uint256 public minConfirmations; // minimal required confirmations
    uint256 public excessConfirmations; // minimal required confirmations in case of too many confirmations
    mapping(uint256 => BlockConfirmationsInfo) public getConfirmationsPerBlock; // block => confirmations

    modifier onlyAdmin {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "onlyAdmin: bad role");
        _;
    }

    struct SubmissionInfo {
        uint256 block; // confirmation block
        uint256 confirmations; // received confirmations count
        mapping(address => bool) hasVerified; // verifier => has already voted
    }
    struct DebridgeDeployInfo {
        address tokenAddress;
        uint256 chainId;
        string name;
        string symbol;
        uint8 decimals;
        uint256 confirmations; // received confirmations count
        mapping(address => bool) hasVerified; // verifier => has already voted
    }
    address public wrappedAssetAdmin;
    address public debridgeAddress;

    mapping(bytes32 => bytes32) public confirmedDeployInfo; // debridge Id => deploy Id
    mapping(bytes32 => DebridgeDeployInfo) public getDeployInfo; // mint id => debridge info
    mapping(bytes32 => address) public override getWrappedAssetAddress; // debridge id => wrapped asset address
    mapping(bytes32 => SubmissionInfo) public getSubmissionInfo; // submission id => submission info

    event Confirmed(bytes32 submissionId, address operator); // emitted once the submission is confirmed by the only oracle
    event SubmissionApproved(bytes32 submissionId); // emitted once the submission is confirmed by all the required oracles
    event DeployConfirmed(bytes32 deployId, address operator); // emitted once the submission is confirmed by one oracle
    event DeployApproved(bytes32 deployId); // emitted once the submission is confirmed by min required aount of oracles

    /// @dev Constructor that initializes the most important configurations.
    /// @param _minConfirmations Common confirmations count.
    /// @param _confirmationThreshold Confirmations per block before extra check enabled.
    /// @param _excessConfirmations Confirmations count in case of excess activity.
    constructor(
        uint256 _minConfirmations,
        uint256 _confirmationThreshold,
        uint256 _excessConfirmations,
        address _wrappedAssetAdmin,
        address _debridgeAddress
    ) {
        confirmationThreshold = _confirmationThreshold;
        minConfirmations = _minConfirmations;
        excessConfirmations = _excessConfirmations;
        wrappedAssetAdmin = _wrappedAssetAdmin;
        debridgeAddress = _debridgeAddress;
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Confirms the transfer request.
    function confirmNewAsset(
        address _tokenAddress,
        uint256 _chainId,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        bytes[] memory _signatures
    ) external {
        bytes32 debridgeId = getDebridgeId(_chainId, _tokenAddress);
        bytes32 deployId = getDeployId(debridgeId, _name, _symbol, _decimals);
        DebridgeDeployInfo storage debridgeInfo = getDeployInfo[deployId];
        require(
            getWrappedAssetAddress[debridgeId] == address(0),
            "deployAsset: deployed already"
        );
        debridgeInfo.name = _name;
        debridgeInfo.symbol = _symbol;
        debridgeInfo.tokenAddress = _tokenAddress;
        debridgeInfo.chainId = _chainId;
        debridgeInfo.decimals = _decimals;
        for (uint256 i = 0; i < _signatures.length; i++) {
            (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signatures[i]);
            bytes32 unsignedMsg = getUnsignedMsg(deployId);
            address oracle = ecrecover(unsignedMsg, v, r, s);
            require(hasRole(ORACLE_ROLE, oracle), "onlyOracle: bad role");
            require(
                !debridgeInfo.hasVerified[oracle],
                "deployAsset: submitted already"
            );
            debridgeInfo.hasVerified[oracle] = true;
            emit DeployConfirmed(deployId, oracle);
            debridgeInfo.confirmations += 1;
        }
        if( debridgeInfo.confirmations >= minConfirmations){
            confirmedDeployInfo[debridgeId] = deployId;
        }
        //TODO: add deployAsset
    }

    /// @dev Confirms the transfer request.
    function deployAsset(bytes32 _debridgeId) 
            external override
            returns (address wrappedAssetAddress, uint256 nativeChainId){
        require(debridgeAddress == msg.sender, "deployAsset: bad role");
        bytes32 deployId = confirmedDeployInfo[_debridgeId];
        //TODO: check 0x
        require(
            deployId != "0x",
            "deployAsset: not found deployId"
        );

        DebridgeDeployInfo storage debridgeInfo = getDeployInfo[deployId];
        require(
            getWrappedAssetAddress[_debridgeId] == address(0),
            "deployAsset: deployed already"
        );
        //TODO: can be removed, we already checked in confirmedDeployInfo
        require(
            debridgeInfo.confirmations >= minConfirmations,
            "deployAsset: not confirmed"
        );
        address[] memory minters = new address[](1);
        minters[0] = debridgeAddress;
        WrappedAsset wrappedAsset = new WrappedAsset(
            debridgeInfo.name,
            debridgeInfo.symbol,
            debridgeInfo.decimals,
            wrappedAssetAdmin,
            minters
        );
        getWrappedAssetAddress[_debridgeId] = address(wrappedAsset);
        emit DeployApproved(deployId);
        return (address(wrappedAsset), debridgeInfo.chainId);
    }

    /// @dev Confirms the mint request.
    /// @param _submissionId Submission identifier.
    /// @param _signatures Array of signatures by oracles.
    function submit(bytes32 _submissionId, bytes[] memory _signatures)
        external
        override
        returns (uint256 _confirmations, bool _blockConfirmationPassed)
    {
        SubmissionInfo storage submissionInfo = getSubmissionInfo[
            _submissionId
        ];
        for (uint256 i = 0; i < _signatures.length; i++) {
            (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signatures[i]);
            bytes32 unsignedMsg = getUnsignedMsg(_submissionId);
            address oracle = ecrecover(unsignedMsg, v, r, s);
            require(hasRole(ORACLE_ROLE, oracle), "onlyOracle: bad role");
            require(
                !submissionInfo.hasVerified[oracle],
                "submit: submitted already"
            );
            submissionInfo.confirmations += 1;
            submissionInfo.hasVerified[oracle] = true;
            emit Confirmed(_submissionId, oracle);
            if (submissionInfo.confirmations >= minConfirmations) {

                    BlockConfirmationsInfo storage _blockConfirmationsInfo
                 = getConfirmationsPerBlock[block.number];
                if (!_blockConfirmationsInfo.isConfirmed[_submissionId]) {
                    _blockConfirmationsInfo.count += 1;
                    _blockConfirmationsInfo.isConfirmed[_submissionId] = true;
                    if (
                        _blockConfirmationsInfo.count >= confirmationThreshold
                    ) {
                        _blockConfirmationsInfo.requireExtraCheck = true;
                    }
                }
                submissionInfo.block = block.number;
                emit SubmissionApproved(_submissionId);
            }
        }
        return (
            submissionInfo.confirmations,
            submissionInfo.confirmations >=
                (
                    (getConfirmationsPerBlock[block.number].requireExtraCheck)
                        ? excessConfirmations
                        : minConfirmations
                )
        );
    }

    /* ADMIN */

    /// @dev Set admin for any deployed wrapped asset.
    /// @param _wrappedAssetAdmin Admin address.
    function setWrappedAssetAdmin(address _wrappedAssetAdmin) public onlyAdmin {
        wrappedAssetAdmin = _wrappedAssetAdmin;
    }

    /// @dev Sets core debridge conrtact address.
    /// @param _debridgeAddress Debridge address.
    function setDebridgeAddress(address _debridgeAddress) public onlyAdmin {
        debridgeAddress = _debridgeAddress;
    }

    /// @dev Sets minimal required confirmations.
    /// @param _minConfirmations Minimal required confirmations.
    function setMinConfirmations(uint256 _minConfirmations) external onlyAdmin {
        minConfirmations = _minConfirmations;
    }

    /// @dev Adds new oracle.
    /// @param _oracle Oracle address.
    function addOracle(address _oracle) external onlyAdmin {
        grantRole(ORACLE_ROLE, _oracle);
    }

    /// @dev Removes oracle.
    /// @param _oracle Oracle address.
    function removeOracle(address _oracle) external onlyAdmin {
        revokeRole(ORACLE_ROLE, _oracle);
    }

    /* VIEW */

    /// @dev Returns whether transfer request is confirmed.
    /// @param _submissionId Submission identifier.
    /// @return _confirmations number of confirmation.
    /// @return _blockConfirmationPassed Whether transfer request is confirmed.
    function getSubmissionConfirmations(bytes32 _submissionId)
        external
        view
        override
        returns (uint256 _confirmations, bool _blockConfirmationPassed)
    {
        SubmissionInfo storage submissionInfo = getSubmissionInfo[
            _submissionId
        ];


            BlockConfirmationsInfo storage _blockConfirmationsInfo
         = getConfirmationsPerBlock[submissionInfo.block];
        _confirmations = submissionInfo.confirmations;
        return (
            _confirmations,
            _confirmations >=
                (
                    (_blockConfirmationsInfo.requireExtraCheck)
                        ? excessConfirmations
                        : minConfirmations
                )
        );
    }

    /// @dev Prepares raw msg that was signed by the oracle.
    /// @param _submissionId Submission identifier.
    function getUnsignedMsg(bytes32 _submissionId)
        public
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    _submissionId
                )
            );
    }

    /// @dev Splits signature bytes to r,s,v components.
    /// @param _signature Signature bytes in format r+s+v.
    function splitSignature(bytes memory _signature)
        public
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        require(
            _signature.length == 65,
            "splitSignature: invalid signature length"
        );
        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }
    }

    /// @dev Calculates asset identifier.
    /// @param _chainId Current chain id.
    /// @param _tokenAddress Address of the asset on the other chain.
    function getDebridgeId(uint256 _chainId, address _tokenAddress)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_chainId, _tokenAddress));
    }

    /// @dev Calculates asset identifier.
    function getDeployId(
        bytes32 _debridgeId,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) public pure returns (bytes32) {
        return
            keccak256(abi.encodePacked(_debridgeId, _name, _symbol, _decimals));
    }
}