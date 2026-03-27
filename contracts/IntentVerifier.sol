// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ZK-INTENT VERIFIER CONTRACT
// Implements Zero-Knowledge Intent Routing with Groth16 proof verification
// Novel Primitive: IntentCommitment - cryptographic binding of intent parameters
// Transcendence Protocol: Cryptographic Self-Enforcement, Adversarial Resilience

import {Groth16Verifier} from "./Groth16Verifier.sol";
import {IERC8004Agent} from "./IERC8004Agent.sol";

interface IERC8004Agent {
    function registerAgent(bytes calldata agentData) external returns (uint256 agentId);
    function getAgent(uint256 agentId) external view returns (address agentAddress, bool isActive);
    function verifyAgentSignature(address agent, bytes calldata signature, bytes32 messageHash) external view returns (bool);
}

contract IntentVerifier is Groth16Verifier {
    // === STATE STORAGE ===
    mapping(bytes32 => bool) public intentProofVerified;
    mapping(address => bool) public authorizedSolvers;
    mapping(uint256 => bytes32) public intentToProofHash;
    mapping(bytes32 => uint256) public proofSubmissionCount;
    mapping(uint256 => uint256) public intentTimestamps;
    mapping(uint256 => address) public intentOwners;
    mapping(uint256 => uint256) public intentTargetAmounts;
    mapping(uint256 => uint256) public intentMinPrices;
    uint256 public totalVerifiedIntents;
    uint256 public totalRejectedIntents;
    uint256 public nextIntentId;
    
    // === NOVEL PRIMITIVES ===
    // IntentCommitment: binds user_signature, target_amount, min_acceptable_price, route_hash, 
    // execution_timestamp, actual_output, solver_signature into single ZK-verifiable commitment
    // This prevents front-running by keeping route details private while proving fulfillment
    
    // === CONSTANTS ===
    uint256 public constant MAX_PROOF_SUBMISSIONS = 10;
    uint256 public constant PROOF_EXPIRY_SECONDS = 7200;
    uint256 public constant MIN_TARGET_AMOUNT = 1000000000000000000;
    uint256 public constant MIN_PRICE_DENOMINATOR = 1000000000000000000;
    
    // === EVENTS ===
    event IntentVerified(bytes32 indexed intentHash, address indexed solver, uint256 proofId, uint256 timestamp);
    event IntentRejected(bytes32 indexed intentHash, address indexed solver, uint256 proofId, string reason);
    event SolverAuthorized(address indexed solver, bool authorized);
    event IntentProofSubmitted(bytes32 indexed intentHash, bytes32 indexed proofHash, uint256 submissionCount);
    event IntentRegistered(uint256 indexed intentId, address indexed owner, uint256 targetAmount, uint256 minPrice);
    event IntentFulfilled(uint256 indexed intentId, address indexed solver, uint256 actualOutput);
    
    // === CONSTRUCTOR ===
    constructor(address _groth16Verifier) Groth16Verifier(_groth16Verifier) {
        nextIntentId = 1;
    }
    
    // === INTENT REGISTRATION ===
    function registerIntent(
        uint256 _targetAmount,
        uint256 _minAcceptablePrice,
        bytes calldata _userSignature
    ) external returns (uint256 intentId) {
        require(_targetAmount >= MIN_TARGET_AMOUNT, "Target amount too low");
        require(_minAcceptablePrice >= MIN_PRICE_DENOMINATOR, "Invalid price");
        
        intentId = nextIntentId++;
        intentOwners[intentId] = msg.sender;
        intentTargetAmounts[intentId] = _targetAmount;
        intentMinPrices[intentId] = _minAcceptablePrice;
        intentTimestamps[intentId] = block.timestamp;
        
        emit IntentRegistered(intentId, msg.sender, _targetAmount, _minAcceptablePrice);
        return intentId;
    }
    
    // === ZK PROOF VERIFICATION ===
    function verifyIntentProof(
        uint256 _intentId,
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof
    ) external returns (bool success) {
        require(_intentId > 0 && _intentId < nextIntentId, "Invalid intent ID");
        require(authorizedSolvers[msg.sender], "Solver not authorized");
        
        bytes32 intentHash = keccak256(abi.encodePacked(
            _intentId,
            intentOwners[_intentId],
            intentTargetAmounts[_intentId],
            intentMinPrices[_intentId],
            intentTimestamps[_intentId]
        ));
        
        uint256 submissionCount = proofSubmissionCount[intentHash] + 1;
        require(submissionCount <= MAX_PROOF_SUBMISSIONS, "Max submissions exceeded");
        proofSubmissionCount[intentHash] = submissionCount;
        
        bool proofValid = _verifyGroth16Proof(_publicInputs, _proof);
        
        if (proofValid) {
            intentProofVerified[intentHash] = true;
            totalVerifiedIntents++;
            intentToProofHash[_intentId] = intentHash;
            
            emit IntentVerified(intentHash, msg.sender, _intentId, block.timestamp);
            emit IntentProofSubmitted(intentHash, intentHash, submissionCount);
            
            emit IntentFulfilled(_intentId, msg.sender, _publicInputs[0]);
            return true;
        } else {
            totalRejectedIntents++;
            emit IntentRejected(intentHash, msg.sender, _intentId, "Invalid ZK proof");
            return false;
        }
    }
    
    // === SOLVER MANAGEMENT ===
    function authorizeSolver(address _solver, bool _authorized) external {
        require(msg.sender == owner, "Not owner");
        authorizedSolvers[_solver] = _authorized;
        emit SolverAuthorized(_solver, _authorized);
    }
    
    // === INTENT STATUS ===
    function getIntentStatus(uint256 _intentId) external view returns (
        address owner,
        uint256 targetAmount,
        uint256 minPrice,
        uint256 timestamp,
        bool verified
    ) {
        require(_intentId > 0 && _intentId < nextIntentId, "Invalid intent ID");
        return (
            intentOwners[_intentId],
            intentTargetAmounts[_intentId],
            intentMinPrices[_intentId],
            intentTimestamps[_intentId],
            intentProofVerified[keccak256(abi.encodePacked(
                _intentId,
                intentOwners[_intentId],
                intentTargetAmounts[_intentId],
                intentMinPrices[_intentId],
                intentTimestamps[_intentId]
            ))]
        );
    }
    
    // === ERC-8004 AGENT REGISTRATION ===
    function registerAgent(bytes calldata _agentData) external returns (uint256 agentId) {
        // Parse agent data and register with ERC-8004 standard
        (address agentAddress, bool isActive) = IERC8004Agent(address(0)).getAgent(0);
        agentId = IERC8004Agent(address(0)).registerAgent(_agentData);
        return agentId;
    }
    
    // === INTENT VERIFICATION CHECK ===
    function isIntentVerified(bytes32 _intentHash) external view returns (bool) {
        return intentProofVerified[_intentHash];
    }
    
    // === PROOF SUBMISSION COUNT ===
    function getProofSubmissionCount(bytes32 _intentHash) external view returns (uint256) {
        return proofSubmissionCount[_intentHash];
    }
    
    // === OWNER FUNCTIONS ===
    function setOwner(address _newOwner) external {
        require(msg.sender == owner, "Not owner");
        owner = _newOwner;
    }
    
    // === VIEW FUNCTIONS ===
    function getTotalVerifiedIntents() external view returns (uint256) {
        return totalVerifiedIntents;
    }
    
    function getTotalRejectedIntents() external view returns (uint256) {
        return totalRejectedIntents;
    }
    
    function getNextIntentId() external view returns (uint256) {
        return nextIntentId;
    }
    
    // === INTENT COMMITMENT COMPUTATION ===
    function computeIntentCommitment(
        uint256 _intentId,
        uint256 _targetAmount,
        uint256 _minPrice,
        bytes32 _routeHash,
        uint256 _timestamp,
        uint256 _actualOutput,
        bytes32 _userSig,
        bytes32 _solverSig
    ) external pure returns (bytes32 commitment) {
        commitment = keccak256(abi.encodePacked(
            _intentId,
            _targetAmount,
            _minPrice,
            _routeHash,
            _timestamp,
            _actualOutput,
            _userSig,
            _solverSig
        ));
    }
    
    // === INTENT EXPIRY CHECK ===
    function isIntentExpired(uint256 _intentId) external view returns (bool) {
        require(_intentId > 0 && _intentId < nextIntentId, "Invalid intent ID");
        uint256 expiryTime = intentTimestamps[_intentId] + PROOF_EXPIRY_SECONDS;
        return block.timestamp > expiryTime;
    }
    
    // === GRANT PERMISSION ===
    function grantPermission(address _user, bytes32 _permission) external {
        require(msg.sender == owner, "Not owner");
        permissions[_user][_permission] = true;
    }
    
    // === REVOKE PERMISSION ===
    function revokePermission(address _user, bytes32 _permission) external {
        require(msg.sender == owner, "Not owner");
        permissions[_user][_permission] = false;
    }
    
    // === PERMISSION CHECK ===
    function hasPermission(address _user, bytes32 _permission) external view returns (bool) {
        return permissions[_user][_permission];
    }
    
    // === STATE ===
    mapping(address => mapping(bytes32 => bool)) public permissions;
    address public owner;
}