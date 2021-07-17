// SPDX-License-Identifier: MIT
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Aggregator.sol";
import "../interfaces/ILightAggregator.sol";
import "../periphery/WrappedAsset.sol";

contract LightAggregator is Aggregator, ILightAggregator {
    struct SubmissionInfo {
        uint256 block; // confirmation block
        uint256 confirmations; // received confirmations count
        bytes[] signatures;
        mapping(address => bool) hasVerified; // verifier => has already voted
    }
    struct DebridgeDeployInfo {
        address tokenAddress;
        uint256 chainId;
        string name;
        string symbol;
        uint8 decimals;
        bool approved;
        uint256 confirmations; // received confirmations count
        bytes[] signatures;
        mapping(address => bool) hasVerified; // verifier => has already voted
    }

    mapping(bytes32 => DebridgeDeployInfo) public getDeployInfo; // mint id => debridge info
    mapping(bytes32 => SubmissionInfo) public getSubmissionInfo; // mint id => submission info

    event Confirmed(bytes32 submissionId, address operator); // emitted once the submission is confirmed by one oracle
    event SubmissionApproved(bytes32 submissionId); // emitted once the submission is confirmed by min required aount of oracles

    /// @dev Constructor that initializes the most important configurations.
    /// @param _minConfirmations Common confirmations count.
    constructor(uint256 _minConfirmations) 
        Aggregator(_minConfirmations)
    {}

    /// @dev Confirms the transfer request.
    function confirmNewAsset(
        address _tokenAddress,
        uint256 _chainId,
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        bytes memory _signature
    ) external onlyOracle {
        bytes32 debridgeId = getDebridgeId(_chainId, _tokenAddress);
        bytes32 deployId = getDeployId(debridgeId, _name, _symbol, _decimals);
        DebridgeDeployInfo storage debridgeInfo = getDeployInfo[deployId];
        require(!debridgeInfo.approved, "deployAsset: submitted already");
        require(
            !debridgeInfo.hasVerified[msg.sender],
            "deployAsset: submitted already"
        );
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);
        bytes32 unsignedMsg = getUnsignedMsg(deployId);
        address oracle = ecrecover(unsignedMsg, v, r, s);
        require(msg.sender == oracle, "onlyOracle: bad role");
        debridgeInfo.confirmations += 1;
        debridgeInfo.name = _name;
        debridgeInfo.symbol = _symbol;
        debridgeInfo.decimals = _decimals;
        debridgeInfo.signatures.push(_signature);
        debridgeInfo.hasVerified[msg.sender] = true;
        if (debridgeInfo.confirmations >= minConfirmations) {
            debridgeInfo.approved = true;
            emit DeployApproved(deployId);
        }
        emit DeployConfirmed(deployId, msg.sender);
    }

    /// @dev Confirms few transfer requests.
    /// @param _submissionIds Submission identifiers.
    /// @param _signatures Oracles signature.
    function submitMany(
        bytes32[] memory _submissionIds,
        bytes[] memory _signatures
    ) external override onlyOracle {
        require(
            _submissionIds.length == _signatures.length,
            "submitMany: signatures and submission count mismatch"
        );
        for (uint256 i; i < _submissionIds.length; i++) {
            _submit(_submissionIds[i], _signatures[i]);
        }
    }

    /// @dev Confirms the transfer request.
    /// @param _submissionId Submission identifier.
    /// @param _signature Oracle's signature.
    function submit(bytes32 _submissionId, bytes memory _signature)
        external
        override
        onlyOracle
    {
        _submit(_submissionId, _signature);
    }

    /// @dev Confirms single transfer request.
    /// @param _submissionId Submission identifier.
    /// @param _signature Oracle's signature.
    function _submit(bytes32 _submissionId, bytes memory _signature) internal {
        SubmissionInfo storage submissionInfo = getSubmissionInfo[
            _submissionId
        ];
        require(
            !submissionInfo.hasVerified[msg.sender],
            "submit: submitted already"
        );
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);
        bytes32 unsignedMsg = getUnsignedMsg(_submissionId);
        address oracle = ecrecover(unsignedMsg, v, r, s);
        require(msg.sender == oracle, "onlyOracle: bad role");
        submissionInfo.confirmations += 1;
        submissionInfo.signatures.push(_signature);
        submissionInfo.hasVerified[msg.sender] = true;
        emit Confirmed(_submissionId, msg.sender);
    }

    /// @dev Returns whether transfer request is confirmed.
    /// @param _submissionId Submission identifier.
    /// @return _confirmations number of confirmation.
    /// @return _confirmed Whether transfer request is confirmed.
    function getSubmissionConfirmations(bytes32 _submissionId)
        external
        view
        override
        returns (uint256 _confirmations, bool _confirmed)
    {
        SubmissionInfo storage submissionInfo = getSubmissionInfo[
            _submissionId
        ];
        _confirmations = submissionInfo.confirmations;
        return (_confirmations, _confirmations >= minConfirmations);
    }

    /// @dev Returns whether transfer request is confirmed.
    /// @param _submissionId Submission identifier.
    /// @return Oracles signatures.
    function getSubmissionSignatures(bytes32 _submissionId)
        external
        view
        returns (bytes[] memory)
    {
        return getSubmissionInfo[_submissionId].signatures;
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
}