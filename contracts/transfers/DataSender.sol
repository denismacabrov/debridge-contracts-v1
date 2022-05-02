// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.7;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../libraries/Flags.sol";
import "../interfaces/IWETH.sol";
import "./DeBridgeGate.sol";

contract DataSender is 
        Initializable,
        AccessControlUpgradeable,
        PausableUpgradeable,
        ReentrancyGuardUpgradeable {

    using Flags for uint256;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SENDDATA_PREFIX = 3;

    uint256 public nonce;

    DeBridgeGate public deBridgeGate;
    IWETH public weth;

    event SentWithFinalty(
        uint32 finality,
        bytes32 submissionId,
        bytes32 indexed debridgeId,
        uint256 amount,
        bytes receiver,
        uint256 nonce,
        uint256 indexed chainIdTo,
            // uint32 referralCode,
            // FeeParams feeParams,
        bytes autoParams,
        address nativeSender
    );

    error TransferAmountNotCoverFees();
    error WrongAutoArgument();
    error EthTransferFailed();

    function initialize(
        IWETH _weth,
        DeBridgeGate _deBridgeGate
    ) public initializer {
        weth = _weth;
        deBridgeGate = _deBridgeGate;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        __ReentrancyGuard_init();
    }

    function send(
        uint256 _chainIdTo,
        bytes memory _receiver,
        uint256 _flags,
        bytes memory _data,
        uint32 _finality
    ) external payable  nonReentrant whenNotPaused {

        payFee(_chainIdTo);

        bytes32 debridgeId = keccak256(abi.encodePacked(getChainId(), address(weth)));

        bytes memory packedSubmission = abi.encodePacked(
            SENDDATA_PREFIX, 
            debridgeId,
            getChainId(),
            _chainIdTo,
            uint(0),
            _receiver,
            nonce
        );
        
        DeBridgeGate.SubmissionAutoParamsTo memory autoParams;

        autoParams.executionFee = 0;
        if (_flags.getFlag(Flags.UNWRAP_ETH)) revert WrongAutoArgument();
        autoParams.flags = _flags;
        autoParams.fallbackAddress = abi.encodePacked(address(0));
        autoParams.data = _data;


        bool isHashedData = autoParams.flags.getFlag(Flags.SEND_HASHED_DATA);
        if (isHashedData && autoParams.data.length != 32) revert WrongAutoArgument();
        // auto submission
        bytes32 submissionId = keccak256(
            abi.encodePacked(
                packedSubmission,
                autoParams.executionFee,
                autoParams.flags,
                keccak256(autoParams.fallbackAddress),
                isHashedData ? autoParams.data : abi.encodePacked(keccak256(autoParams.data)),
                keccak256(abi.encodePacked(msg.sender))
            )
        );

        emit SentWithFinalty(
            _finality,
            submissionId,
            debridgeId,
            uint256(0),
            _receiver,
            nonce,
            _chainIdTo,
                // uint32 referralCode,
                // FeeParams feeParams,
            abi.encode(autoParams),
            msg.sender
        );
        
        nonce++;
    }

    function payFee(
        uint256 chainIdTo_
    ) internal {
        
        uint256 amount_ = msg.value;
        uint256 fixedNativeFee;
        (fixedNativeFee, , ) = deBridgeGate.getChainToConfig(chainIdTo_);
        uint256 assetsFixedFee = fixedNativeFee == 0 ? deBridgeGate.globalFixedNativeFee() : fixedNativeFee;

        uint16 discountFixBps;
        (discountFixBps, ) = deBridgeGate.feeDiscount(msg.sender);
        assetsFixedFee = _applyDiscount(assetsFixedFee, discountFixBps);

        if (amount_ < assetsFixedFee) revert TransferAmountNotCoverFees();
        if (amount_ > assetsFixedFee) {
            _safeTransferETH(msg.sender, amount_ - assetsFixedFee);
        }
    }

    function getChainId() public view virtual returns (uint256 cid) {
        assembly {
            cid := chainid()
        }
    }

    function _applyDiscount(
        uint256 amount,
        uint16 discountBps
    ) internal view returns (uint256) {
        return amount - amount * discountBps / BPS_DENOMINATOR;
    }

    function _safeTransferETH(address _to, uint256 _value) internal {
        (bool success, ) = _to.call{value: _value}(new bytes(0));
        if (!success) revert EthTransferFailed();
    }
}
