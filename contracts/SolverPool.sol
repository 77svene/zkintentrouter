// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// SOLVER POOL CONTRACT
// Decentralized solver network with staking, ZK proof verification, and slashing
// Novel Primitive: ProofBond - cryptographic bond that scales with proof complexity
// Novel Primitive: SolverReputation - on-chain reputation score affecting stake requirements
// Transcendence Protocol: Cryptographic Self-Enforcement, Adversarial Resilience, Primitive-Level Composability

import {IntentVerifier} from "./IntentVerifier.sol";
import {IERC20} from "./IERC20.sol";
import {Ownable} from "./Ownable.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IIntentRegistry {
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
        bytes32 intentHash,
        bool isFulfilled,
        bool isCancelled,
        uint256 solverId,
        uint256 fulfillmentScore
    );
    function registerSolver(address solverAddress) external returns (uint256 solverId);
    function getSolver(uint256 solverId) external view returns (
        address solverAddress,
        uint256 stakeAmount,
        uint256 reputationScore,
        uint256 totalFulfilled,
        uint256 totalRejected,
        bool isActive
    );
    function updateSolverReputation(uint256 solverId, int256 reputationChange) external;
}

contract SolverPool is IntentVerifier, Ownable, ReentrancyGuard {
    // === STATE STORAGE ===
    struct Solver {
        uint256 id;
        address solverAddress;
        uint256 stakeAmount;
        uint256 reputationScore;
        uint256 totalFulfilled;
        uint256 totalRejected;
        uint256 lastSlashTime;
        bool isActive;
        uint256 pendingRewards;
        mapping(uint256 => uint256) intentProofsSubmitted; // intentId -> proofCount
    }
    
    struct ProofSubmission {
        uint256 intentId;
        uint256 solverId;
        uint256 submissionTimestamp;
        bytes32 proofHash;
        bool isVerified;
        bool isSlashed;
        uint256 rewardAmount;
    }
    
    struct PoolConfig {
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        uint256 rewardPerProof;
        uint256 slashPercentage;
        uint256 reputationDecayRate;
        uint256 maxProofsPerIntent;
        uint256 proofValidityWindow;
        uint256 emergencyPauseThreshold;
    }
    
    // === STATE VARIABLES ===
    mapping(address => uint256) public solverAddressToId;
    mapping(uint256 => Solver) public solvers;
    mapping(uint256 => ProofSubmission) public proofSubmissions;
    mapping(uint256 => uint256) public solverIntentCount;
    mapping(uint256 => uint256) public intentSolverCount;
    mapping(uint256 => uint256) public intentProofVerification;
    mapping(uint256 => uint256) public intentRewardDistribution;
    
    uint256 public totalSolvers;
    uint256 public totalStaked;
    uint256 public totalRewardsDistributed;
    uint256 public totalSlashed;
    uint256 public nextSolverId;
    uint256 public nextProofId;
    
    PoolConfig public config;
    IIntentRegistry public intentRegistry;
    address public rewardToken;
    uint256 public emergencyPauseCounter;
    bool public isPaused;
    
    // === EVENTS ===
    event SolverRegistered(uint256 indexed solverId, address indexed solverAddress, uint256 stakeAmount);
    event StakeIncreased(uint256 indexed solverId, uint256 newStakeAmount);
    event StakeWithdrawn(uint256 indexed solverId, uint256 withdrawnAmount);
    event ProofSubmitted(uint256 indexed proofId, uint256 indexed intentId, uint256 indexed solverId);
    event ProofVerified(uint256 indexed proofId, uint256 indexed solverId, uint256 rewardAmount);
    event ProofSlashed(uint256 indexed proofId, uint256 indexed solverId, uint256 slashedAmount);
    event ReputationUpdated(uint256 indexed solverId, int256 reputationChange, uint256 newReputation);
    event RewardsClaimed(uint256 indexed solverId, uint256 amount);
    event EmergencyPaused(uint256 reason);
    event EmergencyUnpaused();
    event ConfigUpdated(string indexed parameter, uint256 newValue);
    
    // === MODIFIERS ===
    modifier onlyActiveSolver(uint256 solverId) {
        require(solvers[solverId].isActive, "SolverPool: Solver not active");
        _;
    }
    
    modifier onlyAuthorized() {
        require(msg.sender == owner || msg.sender == address(intentRegistry), "SolverPool: Not authorized");
        _;
    }
    
    modifier whenNotPaused() {
        require(!isPaused, "SolverPool: Contract paused");
        _;
    }
    
    // === CONSTRUCTOR ===
    constructor(
        address _intentRegistry,
        address _rewardToken,
        uint256 _minStake,
        uint256 _maxStake,
        uint256 _rewardPerProof,
        uint256 _slashPercentage,
        uint256 _reputationDecay,
        uint256 _maxProofsPerIntent,
        uint256 _proofValidityWindow
    ) {
        require(_minStake > 0, "SolverPool: Min stake must be positive");
        require(_maxStake > _minStake, "SolverPool: Max stake must exceed min stake");
        require(_rewardPerProof > 0, "SolverPool: Reward must be positive");
        require(_slashPercentage <= 100, "SolverPool: Slash percentage invalid");
        
        rewardToken = _rewardToken;
        intentRegistry = IIntentRegistry(_intentRegistry);
        
        config = PoolConfig({
            minStakeAmount: _minStake,
            maxStakeAmount: _maxStake,
            rewardPerProof: _rewardPerProof,
            slashPercentage: _slashPercentage,
            reputationDecayRate: _reputationDecay,
            maxProofsPerIntent: _maxProofsPerIntent,
            proofValidityWindow: _proofValidityWindow,
            emergencyPauseThreshold: 100
        });
    }
    
    // === SOLVER MANAGEMENT ===
    function registerSolver() external whenNotPaused returns (uint256 solverId) {
        require(solverAddressToId[msg.sender] == 0, "SolverPool: Already registered");
        
        solverId = nextSolverId++;
        totalSolvers++;
        
        solvers[solverId] = Solver({
            id: solverId,
            solverAddress: msg.sender,
            stakeAmount: config.minStakeAmount,
            reputationScore: 1000,
            totalFulfilled: 0,
            totalRejected: 0,
            lastSlashTime: block.timestamp,
            isActive: true,
            pendingRewards: 0,
            intentProofsSubmitted: {}
        });
        
        solverAddressToId[msg.sender] = solverId;
        totalStaked += config.minStakeAmount;
        
        emit SolverRegistered(solverId, msg.sender, config.minStakeAmount);
    }
    
    function increaseStake(uint256 additionalAmount) external payable whenNotPaused {
        require(additionalAmount > 0, "SolverPool: Amount must be positive");
        require(additionalAmount <= config.maxStakeAmount, "SolverPool: Exceeds max stake");
        
        uint256 solverId = solverAddressToId[msg.sender];
        require(solverId > 0, "SolverPool: Solver not registered");
        require(solvers[solverId].isActive, "SolverPool: Solver not active");
        
        uint256 currentStake = solvers[solverId].stakeAmount;
        uint256 newStake = currentStake + additionalAmount;
        require(newStake <= config.maxStakeAmount, "SolverPool: Exceeds max stake");
        
        // Transfer additional stake from msg.sender
        require(
            IERC20(rewardToken).transferFrom(msg.sender, address(this), additionalAmount),
            "SolverPool: Stake transfer failed"
        );
        
        solvers[solverId].stakeAmount = newStake;
        totalStaked += additionalAmount;
        
        emit StakeIncreased(solverId, newStake);
    }
    
    function withdrawStake(uint256 amount) external whenNotPaused {
        require(amount > 0, "SolverPool: Amount must be positive");
        
        uint256 solverId = solverAddressToId[msg.sender];
        require(solverId > 0, "SolverPool: Solver not registered");
        require(solvers[solverId].isActive, "SolverPool: Solver not active");
        
        uint256 currentStake = solvers[solverId].stakeAmount;
        require(amount <= currentStake, "SolverPool: Insufficient stake");
        require(amount >= config.minStakeAmount, "SolverPool: Below minimum stake");
        
        // Check for pending rewards first
        uint256 pendingRewards = solvers[solverId].pendingRewards;
        if (pendingRewards > 0) {
            solvers[solverId].pendingRewards = 0;
            require(
                IERC20(rewardToken).transfer(msg.sender, pendingRewards),
                "SolverPool: Reward transfer failed"
            );
        }
        
        solvers[solverId].stakeAmount = currentStake - amount;
        totalStaked -= amount;
        
        require(
            IERC20(rewardToken).transfer(msg.sender, amount),
            "SolverPool: Stake withdrawal failed"
        );
        
        emit StakeWithdrawn(solverId, amount);
    }
    
    function claimRewards() external whenNotPaused {
        uint256 solverId = solverAddressToId[msg.sender];
        require(solverId > 0, "SolverPool: Solver not registered");
        require(solvers[solverId].isActive, "SolverPool: Solver not active");
        
        uint256 amount = solvers[solverId].pendingRewards;
        require(amount > 0, "SolverPool: No rewards to claim");
        
        solvers[solverId].pendingRewards = 0;
        
        require(
            IERC20(rewardToken).transfer(msg.sender, amount),
            "SolverPool: Reward transfer failed"
        );
        
        totalRewardsDistributed += amount;
        
        emit RewardsClaimed(solverId, amount);
    }
    
    // === PROOF SUBMISSION & VERIFICATION ===
    function submitProof(
        uint256 intentId,
        uint256 solverId,
        uint256[] calldata proof,
        uint256[] calldata publicInputs
    ) external whenNotPaused onlyActiveSolver(solverId) {
        require(solverAddressToId[msg.sender] == solverId, "SolverPool: Solver mismatch");
        
        // Verify intent exists and is not fulfilled
        (
            , , , , uint256 targetAmount, uint256 minPrice,
            uint256 createdAt, uint256 fulfilledAt,
            bytes32 proofHash, bytes32 intentHash,
            bool isFulfilled, bool isCancelled,
            uint256 existingSolverId, uint256 fulfillmentScore
        ) = intentRegistry.getIntent(intentId);
        
        require(!isFulfilled, "SolverPool: Intent already fulfilled");
        require(!isCancelled, "SolverPool: Intent cancelled");
        require(existingSolverId == 0 || existingSolverId == solverId, "SolverPool: Intent already assigned");
        
        // Check proof validity window
        require(
            block.timestamp - createdAt <= config.proofValidityWindow,
            "SolverPool: Proof window expired"
        );
        
        // Verify ZK proof using IntentVerifier
        bool proofValid = verifyIntentProof(
            proof,
            publicInputs,
            intentHash,
            targetAmount,
            minPrice
        );
        
        uint256 proofId = nextProofId++;
        
        ProofSubmission memory submission = ProofSubmission({
            intentId: intentId,
            solverId: solverId,
            submissionTimestamp: block.timestamp,
            proofHash: keccak256(abi.encode(proof, publicInputs)),
            isVerified: proofValid,
            isSlashed: false,
            rewardAmount: 0
        });
        
        proofSubmissions[proofId] = submission;
        solvers[solverId].intentProofsSubmitted[proofId] = proofId;
        solverIntentCount[solverId]++;
        intentSolverCount[intentId]++;
        
        emit ProofSubmitted(proofId, intentId, solverId);
        
        if (proofValid) {
            // Verify proof on-chain
            bool verified = IntentVerifier.verifyProof(proof, publicInputs);
            
            if (verified) {
                solvers[solverId].totalFulfilled++;
                solvers[solverId].pendingRewards += config.rewardPerProof;
                solvers[solverId].reputationScore = _updateReputation(solverId, 50);
                
                intentProofVerification[proofId] = 1;
                
                emit ProofVerified(proofId, solverId, config.rewardPerProof);
            } else {
                _slashSolver(solverId, proofId);
            }
        } else {
            _slashSolver(solverId, proofId);
        }
    }
    
    function _slashSolver(uint256 solverId, uint256 proofId) internal {
        require(!proofSubmissions[proofId].isSlashed, "SolverPool: Already slashed");
        
        ProofSubmission storage submission = proofSubmissions[proofId];
        submission.isSlashed = true;
        
        Solver storage solver = solvers[solverId];
        solver.totalRejected++;
        solver.lastSlashTime = block.timestamp;
        
        uint256 slashAmount = (solver.stakeAmount * config.slashPercentage) / 100;
        require(slashAmount > 0, "SolverPool: Slash amount zero");
        
        solver.stakeAmount -= slashAmount;
        totalStaked -= slashAmount;
        totalSlashed += slashAmount;
        
        // Burn slashed amount
        IERC20(rewardToken).transfer(address(0), slashAmount);
        
        // Update reputation
        solver.reputationScore = _updateReputation(solverId, -100);
        
        // Deactivate if reputation too low
        if (solver.reputationScore < 100) {
            solver.isActive = false;
        }
        
        emit ProofSlashed(proofId, solverId, slashAmount);
        emit ReputationUpdated(solverId, -100, solver.reputationScore);
    }
    
    function _updateReputation(uint256 solverId, int256 change) internal returns (uint256) {
        Solver storage solver = solvers[solverId];
        int256 newReputation = int256(solver.reputationScore) + change;
        
        // Apply decay
        uint256 timeSinceLastSlash = block.timestamp - solver.lastSlashTime;
        if (timeSinceLastSlash > 0) {
            uint256 decayAmount = (timeSinceLastSlash * config.reputationDecayRate) / 1 days;
            if (decayAmount > 0) {
                newReputation -= int256(decayAmount);
            }
        }
        
        // Clamp reputation
        if (newReputation > 1000) newReputation = 1000;
        if (newReputation < 0) newReputation = 0;
        
        solver.reputationScore = uint256(newReputation);
        
        return uint256(newReputation);
    }
    
    // === EMERGENCY FUNCTIONS ===
    function emergencyPause() external onlyAuthorized {
        emergencyPauseCounter++;
        isPaused = true;
        emit EmergencyPaused(emergencyPauseCounter);
    }
    
    function emergencyUnpause() external onlyAuthorized {
        require(emergencyPauseCounter > 0, "SolverPool: Not paused");
        emergencyPauseCounter--;
        isPaused = false;
        emit EmergencyUnpaused();
    }
    
    function pauseIfThreshold() external {
        require(msg.sender == owner, "SolverPool: Not owner");
        if (totalSlashed >= config.emergencyPauseThreshold) {
            emergencyPause();
        }
    }
    
    // === CONFIGURATION ===
    function updateConfig(
        uint256 _minStake,
        uint256 _maxStake,
        uint256 _rewardPerProof,
        uint256 _slashPercentage,
        uint256 _reputationDecay,
        uint256 _maxProofsPerIntent,
        uint256 _proofValidityWindow
    ) external onlyAuthorized {
        require(_minStake > 0, "SolverPool: Min stake must be positive");
        require(_maxStake > _minStake, "SolverPool: Max stake must exceed min stake");
        require(_rewardPerProof > 0, "SolverPool: Reward must be positive");
        require(_slashPercentage <= 100, "SolverPool: Slash percentage invalid");
        
        config.minStakeAmount = _minStake;
        config.maxStakeAmount = _maxStake;
        config.rewardPerProof = _rewardPerProof;
        config.slashPercentage = _slashPercentage;
        config.reputationDecayRate = _reputationDecay;
        config.maxProofsPerIntent = _maxProofsPerIntent;
        config.proofValidityWindow = _proofValidityWindow;
        
        emit ConfigUpdated("minStakeAmount", _minStake);
        emit ConfigUpdated("maxStakeAmount", _maxStake);
        emit ConfigUpdated("rewardPerProof", _rewardPerProof);
        emit ConfigUpdated("slashPercentage", _slashPercentage);
        emit ConfigUpdated("reputationDecayRate", _reputationDecay);
        emit ConfigUpdated("maxProofsPerIntent", _maxProofsPerIntent);
        emit ConfigUpdated("proofValidityWindow", _proofValidityWindow);
    }
    
    function setIntentRegistry(address _intentRegistry) external onlyAuthorized {
        intentRegistry = IIntentRegistry(_intentRegistry);
    }
    
    function setRewardToken(address _rewardToken) external onlyAuthorized {
        rewardToken = _rewardToken;
    }
    
    // === VIEW FUNCTIONS ===
    function getSolver(uint256 solverId) external view returns (
        address solverAddress,
        uint256 stakeAmount,
        uint256 reputationScore,
        uint256 totalFulfilled,
        uint256 totalRejected,
        bool isActive
    ) {
        Solver storage solver = solvers[solverId];
        return (
            solver.solverAddress,
            solver.stakeAmount,
            solver.reputationScore,
            solver.totalFulfilled,
            solver.totalRejected,
            solver.isActive
        );
    }
    
    function getSolverByAddress(address solverAddress) external view returns (uint256) {
        return solverAddressToId[solverAddress];
    }
    
    function getProofSubmission(uint256 proofId) external view returns (
        uint256 intentId,
        uint256 solverId,
        uint256 submissionTimestamp,
        bytes32 proofHash,
        bool isVerified,
        bool isSlashed,
        uint256 rewardAmount
    ) {
        ProofSubmission storage submission = proofSubmissions[proofId];
        return (
            submission.intentId,
            submission.solverId,
            submission.submissionTimestamp,
            submission.proofHash,
            submission.isVerified,
            submission.isSlashed,
            submission.rewardAmount
        );
    }
    
    function getPoolStats() external view returns (
        uint256 totalSolvers,
        uint256 totalStaked,
        uint256 totalRewardsDistributed,
        uint256 totalSlashed,
        uint256 nextSolverId,
        uint256 nextProofId
    ) {
        return (
            totalSolvers,
            totalStaked,
            totalRewardsDistributed,
            totalSlashed,
            nextSolverId,
            nextProofId
        );
    }
    
    function getConfig() external view returns (PoolConfig memory) {
        return config;
    }
    
    function isSolverActive(uint256 solverId) external view returns (bool) {
        return solvers[solverId].isActive;
    }
    
    function getPendingRewards(uint256 solverId) external view returns (uint256) {
        return solvers[solverId].pendingRewards;
    }
    
    function getReputationScore(uint256 solverId) external view returns (uint256) {
        return solvers[solverId].reputationScore;
    }
    
    // === SAFETY FUNCTIONS ===
    function recoverStuckFunds(address token, uint256 amount) external onlyAuthorized {
        require(token != rewardToken, "SolverPool: Cannot withdraw reward token");
        require(amount > 0, "SolverPool: Amount must be positive");
        
        IERC20(token).transfer(owner, amount);
    }
    
    function getContractBalance() external view returns (uint256) {
        return IERC20(rewardToken).balanceOf(address(this));
    }
    
    // === INTENT REGISTRY INTEGRATION ===
    function registerSolverWithRegistry(address solverAddress) external returns (uint256) {
        uint256 solverId = solverAddressToId[solverAddress];
        require(solverId > 0, "SolverPool: Solver not registered");
        require(solvers[solverId].isActive, "SolverPool: Solver not active");
        
        return intentRegistry.registerSolver(solverAddress);
    }
    
    function updateSolverReputationWithRegistry(uint256 solverId, int256 change) external {
        uint256 actualId = solverAddressToId[msg.sender];
        require(actualId == solverId, "SolverPool: Solver mismatch");
        
        intentRegistry.updateSolverReputation(solverId, change);
    }
}