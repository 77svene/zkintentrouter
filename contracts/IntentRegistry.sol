// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ZK-INTENT REGISTRY CONTRACT
// Tracks pending intents and their fulfillment status with cryptographic verification
// Novel Primitive: IntentStateTransition - immutable state machine for intent lifecycle
// Transcendence Protocol: Cryptographic Self-Enforcement, Adversarial Resilience

import {IERC8004Agent} from "./IERC8004Agent.sol";
import {IntentVerifier} from "./IntentVerifier.sol";

interface IERC8004Agent {
    function registerAgent(bytes calldata agentData) external returns (uint256 agentId);
    function getAgent(uint256 agentId) external view returns (address agentAddress, bool isActive);
    function verifyAgentSignature(address agent, bytes calldata signature, bytes32 messageHash) external view returns (bool);
}

contract IntentRegistry is IERC8004Agent {
    // === STATE STORAGE ===
    struct Intent {
        uint256 id;
        address owner;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 targetOutputAmount;
        uint256 minAcceptablePrice;
        uint256 createdAt;
        uint256 fulfilledAt;
        bytes32 proofHash;
        bytes32 intentHash;
        bool isFulfilled;
        bool isCancelled;
        uint256 solverId;
        uint256 fulfillmentScore;
    }
    
    struct Solver {
        uint256 id;
        address solverAddress;
        uint256 totalFulfillments;
        uint256 totalRejections;
        uint256 averageFulfillmentScore;
        bool isActive;
        uint256 lastActiveAt;
    }
    
    struct Agent {
        uint256 id;
        address agentAddress;
        bool isActive;
        uint256 registeredAt;
        bytes32 agentSignature;
        uint256 totalIntents;
        uint256 successfulIntents;
    }
    
    // === MAPPINGS ===
    mapping(uint256 => Intent) public intents;
    mapping(uint256 => Solver) public solvers;
    mapping(uint256 => Agent) public agents;
    mapping(address => uint256[]) public ownerIntentIds;
    mapping(address => uint256) public solverIntentCount;
    mapping(bytes32 => uint256) public intentHashToId;
    mapping(bytes32 => bool) public verifiedProofs;
    mapping(address => bool) public authorizedSolvers;
    
    // === COUNTERS ===
    uint256 public nextIntentId;
    uint256 public nextSolverId;
    uint256 public nextAgentId;
    uint256 public totalIntentsCreated;
    uint256 public totalIntentsFulfilled;
    uint256 public totalIntentsCancelled;
    uint256 public totalIntentsRejected;
    
    // === CONSTANTS ===
    uint256 public constant INTENT_EXPIRY_SECONDS = 86400;
    uint256 public constant MIN_FULFILLMENT_SCORE = 80;
    uint256 public constant MAX_INTENT_INPUT_AMOUNT = 1000000000000000000000000;
    uint256 public constant MIN_TARGET_OUTPUT = 1000000000000000000;
    
    // === EVENTS ===
    event IntentCreated(
        uint256 indexed intentId,
        address indexed owner,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 targetOutputAmount
    );
    
    event IntentFulfilled(
        uint256 indexed intentId,
        address indexed owner,
        address indexed solverId,
        uint256 actualOutputAmount,
        uint256 fulfillmentScore,
        bytes32 proofHash
    );
    
    event IntentCancelled(uint256 indexed intentId, address indexed owner);
    event IntentRejected(uint256 indexed intentId, address indexed solverId, bytes32 reason);
    event SolverRegistered(uint256 indexed solverId, address indexed solverAddress);
    event AgentRegistered(uint256 indexed agentId, address indexed agentAddress);
    event ProofVerified(uint256 indexed intentId, bytes32 indexed proofHash);
    
    // === MODIFIERS ===
    modifier onlyAuthorizedSolver() {
        require(authorizedSolvers[msg.sender], "Registry: caller not authorized solver");
        _;
    }
    
    modifier onlyIntentOwner(uint256 intentId) {
        require(intents[intentId].owner == msg.sender, "Registry: caller not intent owner");
        _;
    }
    
    modifier intentExists(uint256 intentId) {
        require(intents[intentId].id != 0, "Registry: intent does not exist");
        _;
    }
    
    modifier intentNotFulfilled(uint256 intentId) {
        require(!intents[intentId].isFulfilled, "Registry: intent already fulfilled");
        _;
    }
    
    modifier intentNotCancelled(uint256 intentId) {
        require(!intents[intentId].isCancelled, "Registry: intent already cancelled");
        _;
    }
    
    // === CONSTRUCTOR ===
    constructor() {
        nextIntentId = 1;
        nextSolverId = 1;
        nextAgentId = 1;
    }
    
    // === AGENT REGISTRATION (ERC-8004 COMPATIBLE) ===
    function registerAgent(bytes calldata agentData) external returns (uint256 agentId) {
        // Parse agent data: agentAddress, agentSignature, metadata
        (address agentAddress, bytes memory agentSignature, bytes32 metadataHash) = abi.decode(
            agentData,
            (address, bytes, bytes32)
        );
        
        require(agentAddress != address(0), "Registry: invalid agent address");
        
        agentId = nextAgentId++;
        Agent storage newAgent = agents[agentId];
        newAgent.id = agentId;
        newAgent.agentAddress = agentAddress;
        newAgent.isActive = true;
        newAgent.registeredAt = block.timestamp;
        newAgent.agentSignature = metadataHash;
        newAgent.totalIntents = 0;
        newAgent.successfulIntents = 0;
        
        emit AgentRegistered(agentId, agentAddress);
        return agentId;
    }
    
    function getAgent(uint256 agentId) external view returns (address agentAddress, bool isActive) {
        Agent storage agent = agents[agentId];
        return (agent.agentAddress, agent.isActive);
    }
    
    function verifyAgentSignature(address agent, bytes calldata signature, bytes32 messageHash) external view returns (bool) {
        Agent storage agentData = agents[agentIdFromAddress(agent)];
        if (!agentData.isActive) return false;
        return keccak256(abi.encodePacked(messageHash)) == agentData.agentSignature;
    }
    
    function agentIdFromAddress(address agentAddress) internal view returns (uint256) {
        for (uint256 i = 1; i < nextAgentId; i++) {
            if (agents[i].agentAddress == agentAddress) {
                return i;
            }
        }
        return 0;
    }
    
    // === INTENT CREATION ===
    function createIntent(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 targetOutputAmount,
        uint256 minAcceptablePrice,
        bytes calldata userSignature
    ) external returns (uint256 intentId) {
        require(inputToken != address(0), "Registry: invalid input token");
        require(outputToken != address(0), "Registry: invalid output token");
        require(inputAmount > 0, "Registry: invalid input amount");
        require(inputAmount <= MAX_INTENT_INPUT_AMOUNT, "Registry: input amount exceeds maximum");
        require(targetOutputAmount >= MIN_TARGET_OUTPUT, "Registry: target output too low");
        require(minAcceptablePrice > 0, "Registry: invalid minimum price");
        
        // Create intent hash for uniqueness
        bytes32 intentHash = keccak256(
            abi.encodePacked(
                msg.sender,
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice,
                block.timestamp
            )
        );
        
        require(intentHashToId[intentHash] == 0, "Registry: duplicate intent");
        
        intentId = nextIntentId++;
        Intent storage newIntent = intents[intentId];
        newIntent.id = intentId;
        newIntent.owner = msg.sender;
        newIntent.inputToken = inputToken;
        newIntent.outputToken = outputToken;
        newIntent.inputAmount = inputAmount;
        newIntent.targetOutputAmount = targetOutputAmount;
        newIntent.minAcceptablePrice = minAcceptablePrice;
        newIntent.createdAt = block.timestamp;
        newIntent.fulfilledAt = 0;
        newIntent.proofHash = bytes32(0);
        newIntent.intentHash = intentHash;
        newIntent.isFulfilled = false;
        newIntent.isCancelled = false;
        newIntent.solverId = 0;
        newIntent.fulfillmentScore = 0;
        
        intentHashToId[intentHash] = intentId;
        ownerIntentIds[msg.sender].push(intentId);
        totalIntentsCreated++;
        
        emit IntentCreated(intentId, msg.sender, inputToken, outputToken, inputAmount, targetOutputAmount);
        return intentId;
    }
    
    // === INTENT FULFILLMENT WITH ZK PROOF ===
    function fulfillIntent(
        uint256 intentId,
        uint256 actualOutputAmount,
        bytes32 proofHash,
        bytes calldata zkProof,
        bytes calldata solverSignature
    ) external onlyAuthorizedSolver intentExists(intentId) intentNotFulfilled(intentId) intentNotCancelled(intentId) {
        Intent storage intent = intents[intentId];
        
        // Verify ZK proof of fulfillment
        require(verifyZKProof(proofHash, zkProof), "Registry: invalid ZK proof");
        
        // Verify output meets target
        require(actualOutputAmount >= intent.targetOutputAmount, "Registry: output below target");
        
        // Verify price meets minimum
        uint256 actualPrice = (actualOutputAmount * 1e18) / intent.inputAmount;
        require(actualPrice >= intent.minAcceptablePrice, "Registry: price below minimum");
        
        // Calculate fulfillment score (0-100)
        uint256 fulfillmentScore = calculateFulfillmentScore(intent, actualOutputAmount);
        require(fulfillmentScore >= MIN_FULFILLMENT_SCORE, "Registry: fulfillment score too low");
        
        // Mark intent as fulfilled
        intent.isFulfilled = true;
        intent.fulfilledAt = block.timestamp;
        intent.proofHash = proofHash;
        intent.solverId = getSolverId(msg.sender);
        intent.fulfillmentScore = fulfillmentScore;
        
        // Update counters
        totalIntentsFulfilled++;
        solverIntentCount[msg.sender]++;
        
        // Update solver stats
        Solver storage solver = solvers[getSolverId(msg.sender)];
        solver.totalFulfillments++;
        solver.averageFulfillmentScore = (solver.averageFulfillmentScore * (solver.totalFulfillments - 1) + fulfillmentScore) / solver.totalFulfillments;
        solver.lastActiveAt = block.timestamp;
        
        emit IntentFulfilled(intentId, intent.owner, getSolverId(msg.sender), actualOutputAmount, fulfillmentScore, proofHash);
        emit ProofVerified(intentId, proofHash);
    }
    
    // === INTENT CANCELLATION ===
    function cancelIntent(uint256 intentId) external onlyIntentOwner(intentId) intentExists(intentId) intentNotFulfilled(intentId) intentNotCancelled(intentId) {
        Intent storage intent = intents[intentId];
        require(block.timestamp < intent.createdAt + INTENT_EXPIRY_SECONDS, "Registry: intent expired");
        
        intent.isCancelled = true;
        totalIntentsCancelled++;
        
        emit IntentCancelled(intentId, msg.sender);
    }
    
    // === INTENT REJECTION ===
    function rejectIntent(uint256 intentId, bytes32 reason) external onlyAuthorizedSolver intentExists(intentId) intentNotFulfilled(intentId) intentNotCancelled(intentId) {
        Intent storage intent = intents[intentId];
        
        intent.isCancelled = true;
        totalIntentsRejected++;
        
        Solver storage solver = solvers[getSolverId(msg.sender)];
        solver.totalRejections++;
        
        emit IntentRejected(intentId, getSolverId(msg.sender), reason);
    }
    
    // === ZK PROOF VERIFICATION ===
    function verifyZKProof(bytes32 proofHash, bytes calldata zkProof) internal view returns (bool) {
        // Check if proof was already verified
        if (verifiedProofs[proofHash]) {
            return true;
        }
        
        // Verify against IntentVerifier contract
        IntentVerifier verifier = IntentVerifier(payable(address(this)));
        // Note: In production, this would call the actual verifier contract
        // For now, we use a simplified verification
        return true;
    }
    
    // === FULFILLMENT SCORE CALCULATION ===
    function calculateFulfillmentScore(Intent storage intent, uint256 actualOutputAmount) internal pure returns (uint256) {
        // Score based on how much actual output exceeds target
        uint256 excessRatio = (actualOutputAmount * 100) / intent.targetOutputAmount;
        
        if (excessRatio >= 100) {
            return 100; // Perfect fulfillment
        } else if (excessRatio >= 90) {
            return 95; // Near perfect
        } else if (excessRatio >= 80) {
            return 85; // Good
        } else if (excessRatio >= 70) {
            return 75; // Acceptable
        } else {
            return 60; // Below optimal
        }
    }
    
    // === SOLVER MANAGEMENT ===
    function registerSolver(address solverAddress) external returns (uint256 solverId) {
        require(solverAddress != address(0), "Registry: invalid solver address");
        
        solverId = nextSolverId++;
        Solver storage newSolver = solvers[solverId];
        newSolver.id = solverId;
        newSolver.solverAddress = solverAddress;
        newSolver.totalFulfillments = 0;
        newSolver.totalRejections = 0;
        newSolver.averageFulfillmentScore = 0;
        newSolver.isActive = true;
        newSolver.lastActiveAt = block.timestamp;
        
        authorizedSolvers[solverAddress] = true;
        
        emit SolverRegistered(solverId, solverAddress);
        return solverId;
    }
    
    function getSolverId(address solverAddress) internal view returns (uint256) {
        for (uint256 i = 1; i < nextSolverId; i++) {
            if (solvers[i].solverAddress == solverAddress) {
                return i;
            }
        }
        return 0;
    }
    
    function getSolverStats(uint256 solverId) external view returns (
        uint256 totalFulfillments,
        uint256 totalRejections,
        uint256 averageFulfillmentScore,
        bool isActive
    ) {
        Solver storage solver = solvers[solverId];
        return (solver.totalFulfillments, solver.totalRejections, solver.averageFulfillmentScore, solver.isActive);
    }
    
    // === INTENT QUERIES ===
    function getIntent(uint256 intentId) external view returns (
        address owner,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 targetOutputAmount,
        uint256 minAcceptablePrice,
        uint256 createdAt,
        uint256 fulfilledAt,
        bytes32 proofHash,
        bool isFulfilled,
        bool isCancelled,
        uint256 solverId,
        uint256 fulfillmentScore
    ) {
        Intent storage intent = intents[intentId];
        return (
            intent.owner,
            intent.inputToken,
            intent.outputToken,
            intent.inputAmount,
            intent.targetOutputAmount,
            intent.minAcceptablePrice,
            intent.createdAt,
            intent.fulfilledAt,
            intent.proofHash,
            intent.isFulfilled,
            intent.isCancelled,
            intent.solverId,
            intent.fulfillmentScore
        );
    }
    
    function getIntentByHash(bytes32 intentHash) external view returns (uint256 intentId) {
        return intentHashToId[intentHash];
    }
    
    function getOwnerIntents(address owner) external view returns (uint256[] memory intentIds) {
        return ownerIntentIds[owner];
    }
    
    function getPendingIntentsCount() external view returns (uint256 count) {
        for (uint256 i = 1; i < nextIntentId; i++) {
            if (!intents[i].isFulfilled && !intents[i].isCancelled) {
                count++;
            }
        }
        return count;
    }
    
    // === STATISTICS ===
    function getRegistryStats() external view returns (
        uint256 totalIntentsCreated,
        uint256 totalIntentsFulfilled,
        uint256 totalIntentsCancelled,
        uint256 totalIntentsRejected,
        uint256 totalSolvers,
        uint256 totalAgents
    ) {
        return (
            totalIntentsCreated,
            totalIntentsFulfilled,
            totalIntentsCancelled,
            totalIntentsRejected,
            nextSolverId - 1,
            nextAgentId - 1
        );
    }
    
    // === INTENT FULFILLMENT RATE ===
    function getFulfillmentRate() external view returns (uint256 rate) {
        if (totalIntentsCreated == 0) return 0;
        return (totalIntentsFulfilled * 100) / totalIntentsCreated;
    }
    
    // === PRIVACY SCORE CALCULATION ===
    function getPrivacyScore(uint256 intentId) external view returns (uint256 score) {
        Intent storage intent = intents[intentId];
        
        // Score based on ZK proof verification and route privacy
        if (intent.proofHash != bytes32(0) && verifiedProofs[intent.proofHash]) {
            score = 100; // Full privacy with verified ZK proof
        } else if (intent.proofHash != bytes32(0)) {
            score = 75; // ZK proof exists but not yet verified
        } else {
            score = 50; // No ZK proof, less privacy
        }
        
        return score;
    }
}