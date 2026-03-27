// SPDX-License-Identifier: MIT
// ZK-INTENT ROUTER - SOLVER SERVICE
// Listens for intents, calculates optimal routes, generates ZK proofs, submits to SolverPool.sol
// Transcendence Protocol: Cryptographic Self-Enforcement, Adversarial Resilience

const { WebSocket } = require('ws');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

// Configuration from environment (no hardcoded secrets)
const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'http://localhost:8545',
  PRIVATE_KEY: process.env.PRIVATE_KEY || '',
  SOLVER_POOL_ADDRESS: process.env.SOLVER_POOL_ADDRESS || '0x0000000000000000000000000000000000000000',
  INTENT_REGISTRY_ADDRESS: process.env.INTENT_REGISTRY_ADDRESS || '0x0000000000000000000000000000000000000000',
  WS_ENDPOINT: process.env.WS_ENDPOINT || 'ws://localhost:8545',
  CIRCUIT_DIR: path.join(__dirname, '..', 'circuits'),
  PROOF_DIR: path.join(__dirname, '..', 'proofs'),
  AGENT_ID: process.env.AGENT_ID || 'solver-001',
  MAX_GAS_PRICE: process.env.MAX_GAS_PRICE ? parseInt(process.env.MAX_GAS_PRICE) : 100000000000,
  MIN_PROFIT_THRESHOLD: process.env.MIN_PROFIT_THRESHOLD ? parseFloat(process.env.MIN_PROFIT_THRESHOLD) : 0.001,
  INTENT_TIMEOUT_SECONDS: parseInt(process.env.INTENT_TIMEOUT_SECONDS) || 300,
};

// Validate required configuration
if (!CONFIG.PRIVATE_KEY) {
  throw new Error('PRIVATE_KEY environment variable is required');
}

// Initialize ethers provider and wallet
const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);
const wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider);

// Contract ABIs
const SOLVER_POOL_ABI = [
  'function submitIntentProof(uint256 intentId, bytes32[] calldata proof, bytes32 publicSignals) external returns (bool)',
  'function registerSolver(address solverAddress) external',
  'function getPendingIntents() external view returns (uint256[] memory)',
  'function getSolverStats(address solver) external view returns (uint256 fulfilled, uint256 total)',
  'event IntentSubmitted(uint256 indexed intentId, address indexed owner, address inputToken, address outputToken, uint256 inputAmount, uint256 targetOutputAmount)',
  'event ProofSubmitted(uint256 indexed intentId, address indexed solver, bool success)',
  'event SolverRegistered(address indexed solver, uint256 indexed solverId)',
];

const INTENT_REGISTRY_ABI = [
  'function getPendingIntents() external view returns (uint256[] memory)',
  'function getIntent(uint256 intentId) external view returns (uint256 id, address owner, address inputToken, address outputToken, uint256 inputAmount, uint256 targetOutputAmount, uint256 minAcceptablePrice, uint256 createdAt, bool isFulfilled)',
  'function cancelIntent(uint256 intentId) external',
  'event IntentCancelled(uint256 indexed intentId, address indexed owner)',
];

// Service state
const serviceState = {
  isRunning: false,
  intentsProcessed: 0,
  proofsGenerated: 0,
  submissionsSuccessful: 0,
  submissionsFailed: 0,
  lastHeartbeat: Date.now(),
  activeIntents: new Map(),
};

// Initialize WebSocket connection for intent listening
class IntentWebSocket {
  constructor(endpoint) {
    this.endpoint = endpoint;
    this.ws = null;
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 10;
    this.reconnectDelay = 1000;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(this.endpoint);

      this.ws.on('open', () => {
        console.log('[IntentWebSocket] Connected to WebSocket endpoint');
        this.reconnectAttempts = 0;
        resolve();
      });

      this.ws.on('message', (data) => {
        try {
          const message = JSON.parse(data.toString());
          this.handleMessage(message);
        } catch (error) {
          console.error('[IntentWebSocket] Failed to parse message:', error.message);
        }
      });

      this.ws.on('error', (error) => {
        console.error('[IntentWebSocket] WebSocket error:', error.message);
        reject(error);
      });

      this.ws.on('close', () => {
        console.log('[IntentWebSocket] Connection closed');
        this.attemptReconnect();
      });
    });
  }

  handleMessage(message) {
    if (message.event === 'IntentSubmitted') {
      this.emitIntent(message.data);
    }
  }

  emitIntent(intentData) {
    console.log('[IntentWebSocket] New intent received:', intentData.intentId);
    serviceState.activeIntents.set(intentData.intentId, {
      ...intentData,
      receivedAt: Date.now(),
      status: 'pending',
    });
  }

  attemptReconnect() {
    if (this.reconnectAttempts < this.maxReconnectAttempts) {
      this.reconnectAttempts++;
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
      console.log(`[IntentWebSocket] Reconnecting in ${this.reconnectDelay}ms (attempt ${this.reconnectAttempts})`);
      setTimeout(() => this.connect(), this.reconnectDelay);
    } else {
      console.error('[IntentWebSocket] Max reconnect attempts reached');
    }
  }

  close() {
    if (this.ws) {
      this.ws.close();
    }
  }
}

// Route calculator using 1inch/ParaSwap API integration
class RouteCalculator {
  constructor() {
    this.aggregatorEndpoints = {
      '1inch': 'https://api.1inch.dev/swap/v6.0',
      'paraswap': 'https://api.paraswap.io',
    };
    this.apiKeys = {
      '1inch': process.env.ONEINCH_API_KEY || '',
      'paraswap': process.env.PARASWAP_API_KEY || '',
    };
  }

  async calculateRoute(inputToken, outputToken, inputAmount, chainId) {
    const routes = [];

    // Try 1inch aggregator
    if (this.apiKeys['1inch']) {
      try {
        const response = await fetch(
          `${this.aggregatorEndpoints['1inch']}/${chainId}/swap?fromTokenAddress=${inputToken}&toTokenAddress=${outputToken}&amount=${inputAmount}&slippage=0.5`,
          {
            headers: {
              'Authorization': `Bearer ${this.apiKeys['1inch']}`,
            },
          }
        );

        if (response.ok) {
          const data = await response.json();
          routes.push({
            aggregator: '1inch',
            fromToken: inputToken,
            toToken: outputToken,
            fromAmount: inputAmount.toString(),
            toAmount: data.toTokenAmount,
            priceRoute: data.priceRoute,
            gasCost: data.estimatedGas,
          });
        }
      } catch (error) {
        console.error('[RouteCalculator] 1inch route calculation failed:', error.message);
      }
    }

    // Try ParaSwap aggregator
    if (this.apiKeys['paraswap']) {
      try {
        const response = await fetch(
          `${this.aggregatorEndpoints['paraswap']}/prices?fromToken=${inputToken}&toToken=${outputToken}&amount=${inputAmount}&side=SELL&network=${chainId}`,
          {
            headers: {
              'x-api-key': this.apiKeys['paraswap'],
            },
          }
        );

        if (response.ok) {
          const data = await response.json();
          routes.push({
            aggregator: 'paraswap',
            fromToken: inputToken,
            toToken: outputToken,
            fromAmount: inputAmount.toString(),
            toAmount: data.toTokenAmount,
            priceRoute: data,
            gasCost: data.estimatedGas,
          });
        }
      } catch (error) {
        console.error('[RouteCalculator] ParaSwap route calculation failed:', error.message);
      }
    }

    // Return best route by output amount
    if (routes.length === 0) {
      throw new Error('No valid routes found');
    }

    const bestRoute = routes.reduce((best, current) =>
      BigInt(current.toAmount) > BigInt(best.toAmount) ? current : best
    );

    return bestRoute;
  }

  calculateRouteHash(route) {
    const routeString = JSON.stringify({
      aggregator: route.aggregator,
      path: route.priceRoute?.route?.map(r => r.tokenAddresses).flat() || [],
      amountIn: route.fromAmount,
      amountOut: route.toAmount,
    });
    return ethers.keccak256(ethers.toUtf8Bytes(routeString));
  }
}

// ZK Proof generator using SnarkJS
class ZKProofGenerator {
  constructor(circuitDir, proofDir) {
    this.circuitDir = circuitDir;
    this.proofDir = proofDir;
    this.wasmPath = path.join(circuitDir, 'intentRouter.wasm');
    this.zkeyPath = path.join(circuitDir, 'intentRouter_final.zkey');
    this.vkeyPath = path.join(circuitDir, 'verification_key.json');
  }

  async generateProof(intent, route) {
    const input = {
      user_signature: intent.userSignature || ethers.randomBytes(32),
      target_amount: intent.targetOutputAmount.toString(),
      min_acceptable_price: intent.minAcceptablePrice.toString(),
      route_hash: route.hash || ethers.randomBytes(32),
      actual_output: route.toAmount.toString(),
      execution_timestamp: Math.floor(Date.now() / 1000),
      solver_signature: ethers.randomBytes(64),
      solver_pubkey: [ethers.randomBytes(32), ethers.randomBytes(32)],
    };

    try {
      // Generate witness
      const witness = await execSync(
        `node ${path.join(this.circuitDir, 'calculate_witness.js')} ${JSON.stringify(input)}`,
        { encoding: 'utf-8' }
      );

      // Generate proof
      const proof = await execSync(
        `snarkjs groth16 prove ${this.zkeyPath} ${this.wasmPath} witness.wtns proof.json public.json`,
        { cwd: this.circuitDir, encoding: 'utf-8' }
      );

      // Read proof files
      const proofData = JSON.parse(fs.readFileSync(path.join(this.proofDir, 'proof.json'), 'utf-8'));
      const publicSignals = JSON.parse(fs.readFileSync(path.join(this.proofDir, 'public.json'), 'utf-8'));

      return {
        proof: [
          proofData.pi_a[0],
          proofData.pi_a[1],
          proofData.pi_b[0],
          proofData.pi_b[1],
          proofData.pi_c[0],
          proofData.pi_c[1],
        ],
        publicSignals: [
          publicSignals[0],
          publicSignals[1],
          publicSignals[2],
          publicSignals[3],
          publicSignals[4],
          publicSignals[5],
          publicSignals[6],
          publicSignals[7],
        ],
      };
    } catch (error) {
      console.error('[ZKProofGenerator] Proof generation failed:', error.message);
      throw error;
    }
  }

  async verifyProof(proof, publicSignals) {
    try {
      const vkey = JSON.parse(fs.readFileSync(this.vkeyPath, 'utf-8'));
      const isValid = await execSync(
        `snarkjs groth16 verify ${this.vkeyPath} ${JSON.stringify(publicSignals)} ${JSON.stringify(proof)}`,
        { encoding: 'utf-8' }
      );
      return isValid.includes('true');
    } catch (error) {
      console.error('[ZKProofGenerator] Proof verification failed:', error.message);
      return false;
    }
  }
}

// Main solver service
class SolverService {
  constructor() {
    this.intentWs = new IntentWebSocket(CONFIG.WS_ENDPOINT);
    this.routeCalculator = new RouteCalculator();
    this.zkGenerator = new ZKProofGenerator(CONFIG.CIRCUIT_DIR, CONFIG.PROOF_DIR);
    this.solverPool = new ethers.Contract(CONFIG.SOLVER_POOL_ADDRESS, SOLVER_POOL_ABI, wallet);
    this.intentRegistry = new ethers.Contract(CONFIG.INTENT_REGISTRY_ADDRESS, INTENT_REGISTRY_ABI, provider);
  }

  async initialize() {
    console.log('[SolverService] Initializing...');

    // Register solver with pool
    try {
      const tx = await this.solverPool.registerSolver(wallet.address);
      await tx.wait();
      console.log('[SolverService] Solver registered successfully');
    } catch (error) {
      console.error('[SolverService] Solver registration failed:', error.message);
    }

    // Start WebSocket listener
    await this.intentWs.connect();

    // Start processing intents
    this.isRunning = true;
    this.processIntentsLoop();
  }

  async processIntentsLoop() {
    while (this.isRunning) {
      try {
        const pendingIntents = await this.intentRegistry.getPendingIntents();

        for (const intentId of pendingIntents) {
          if (!serviceState.activeIntents.has(intentId)) {
            continue;
          }

          const intent = serviceState.activeIntents.get(intentId);

          // Check timeout
          if (Date.now() - intent.receivedAt > CONFIG.INTENT_TIMEOUT_SECONDS * 1000) {
            console.log(`[SolverService] Intent ${intentId} timed out`);
            serviceState.activeIntents.delete(intentId);
            continue;
          }

          // Calculate route
          const route = await this.routeCalculator.calculateRoute(
            intent.inputToken,
            intent.outputToken,
            intent.inputAmount,
            1 // Mainnet chain ID
          );

          // Check profit threshold
          const profit = (BigInt(route.toAmount) - BigInt(intent.targetOutputAmount)) / BigInt(intent.inputAmount);
          if (profit < BigInt(Math.floor(CONFIG.MIN_PROFIT_THRESHOLD * 1e18))) {
            console.log(`[SolverService] Intent ${intentId} below profit threshold`);
            continue;
          }

          // Generate ZK proof
          const proofData = await this.zkGenerator.generateProof(intent, route);

          // Verify proof locally
          const isValid = await this.zkGenerator.verifyProof(proofData.proof, proofData.publicSignals);
          if (!isValid) {
            console.error(`[SolverService] Invalid proof for intent ${intentId}`);
            serviceState.submissionsFailed++;
            continue;
          }

          // Submit proof to SolverPool
          const tx = await this.solverPool.submitIntentProof(
            intentId,
            proofData.proof,
            proofData.publicSignals[0]
          );

          await tx.wait();
          console.log(`[SolverService] Intent ${intentId} proof submitted successfully`);

          serviceState.intentsProcessed++;
          serviceState.proofsGenerated++;
          serviceState.submissionsSuccessful++;
          serviceState.activeIntents.delete(intentId);

        }
      } catch (error) {
        console.error('[SolverService] Error processing intents:', error.message);
      }

      await new Promise(resolve => setTimeout(resolve, 5000));
    }
  }

  getStats() {
    return {
      intentsProcessed: serviceState.intentsProcessed,
      proofsGenerated: serviceState.proofsGenerated,
      submissionsSuccessful: serviceState.submissionsSuccessful,
      submissionsFailed: serviceState.submissionsFailed,
      activeIntents: serviceState.activeIntents.size,
      uptime: Date.now() - serviceState.lastHeartbeat,
    };
  }

  stop() {
    this.isRunning = false;
    this.intentWs.close();
    console.log('[SolverService] Stopped');
  }
}

// Export for use in agent service
module.exports = { SolverService, CONFIG };

// Run if executed directly
if (require.main === module) {
  const service = new SolverService();
  service.initialize().catch(console.error);

  process.on('SIGINT', () => {
    service.stop();
    process.exit(0);
  });

  process.on('SIGTERM', () => {
    service.stop();
    process.exit(0);
  });
}