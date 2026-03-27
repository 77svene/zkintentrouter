// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ZK-INTENT ROUTER DEPLOYMENT SCRIPT
// Automates deployment of all contracts to Sepolia testnet
// Configures environment variables for API keys and ZK keys
// Outputs deployment addresses to deployments.json

const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

// Environment variable validation - no hardcoded secrets
const validateEnv = () => {
  const required = [
    "SEPOLIA_RPC_URL",
    "PRIVATE_KEY",
    "PARASWAP_API_KEY",
    "ZK_PROVER_URL",
    "ZK_VERIFIER_ADDRESS"
  ];
  
  const missing = required.filter(key => !process.env[key]);
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(", ")}`);
  }
};

// Deploy a single contract with verification
const deployContract = async (contractName, constructorArgs = []) => {
  console.log(`\n🔨 Deploying ${contractName}...`);
  
  const ContractFactory = await hre.ethers.getContractFactory(contractName);
  const contract = await ContractFactory.deploy(...constructorArgs);
  await contract.waitForDeployment();
  
  const address = await contract.getAddress();
  console.log(`✅ ${contractName} deployed to: ${address}`);
  
  return {
    name: contractName,
    address: address,
    contract: contract
  };
};

// Generate deployment manifest
const generateDeploymentManifest = (deployments) => {
  const manifest = {
    network: hre.network.name,
    chainId: hre.network.config.chainId,
    timestamp: Date.now(),
    contracts: {}
  };
  
  deployments.forEach(deploy => {
    manifest.contracts[deploy.name] = {
      address: deploy.address,
      deployedAt: new Date().toISOString(),
      constructorArgs: deploy.constructorArgs || []
    };
  });
  
  return manifest;
};

// Main deployment function
const main = async () => {
  console.log("🚀 ZK-Intent Router Deployment - Sepolia Testnet");
  console.log("=" .repeat(60));
  
  // Validate environment variables
  validateEnv();
  
  // Get deployer account
  const [deployer] = await hre.ethers.getSigners();
  const balance = await deployer.getBalance();
  console.log(`\n👤 Deployer: ${deployer.address}`);
  console.log(`💰 Balance: ${hre.ethers.formatEther(balance)} ETH`);
  
  // Check gas price
  const gasPrice = await hre.ethers.provider.getGasPrice();
  console.log(`⛽ Gas Price: ${hre.ethers.formatUnits(gasPrice, "gwei")} gwei`);
  
  const deployments = [];
  
  try {
    // 1. Deploy Groth16 Verifier (base contract for ZK proofs)
    const verifier = await deployContract("Groth16Verifier");
    deployments.push(verifier);
    
    // 2. Deploy Intent Registry (intent state management)
    const registry = await deployContract("IntentRegistry");
    deployments.push(registry);
    
    // 3. Deploy Intent Verifier (ZK proof verification)
    const intentVerifier = await deployContract("IntentVerifier", [
      verifier.address
    ]);
    deployments.push(intentVerifier);
    
    // 4. Deploy Solver Pool (solver staking and verification)
    const solverPool = await deployContract("SolverPool", [
      intentVerifier.address,
      registry.address
    ]);
    deployments.push(solverPool);
    
    // 5. Initialize registry with verifier
    const tx = await registry.initialize(intentVerifier.address);
    await tx.wait();
    console.log("✅ Intent Registry initialized with verifier");
    
    // 6. Initialize solver pool with registry
    const tx2 = await solverPool.initialize(registry.address);
    await tx2.wait();
    console.log("✅ Solver Pool initialized with registry");
    
    // Generate deployment manifest
    const manifest = generateDeploymentManifest(deployments);
    
    // Save to deployments.json
    const deployDir = path.join(__dirname, "..");
    const deployPath = path.join(deployDir, "deployments.json");
    fs.writeFileSync(deployPath, JSON.stringify(manifest, null, 2));
    console.log(`\n💾 Deployment manifest saved to: ${deployPath}`);
    
    // Print summary
    console.log("\n" + "=".repeat(60));
    console.log("📋 DEPLOYMENT SUMMARY");
    console.log("=".repeat(60));
    
    for (const deploy of deployments) {
      console.log(`${deploy.name.padEnd(25)} ${deploy.address}`);
    }
    
    console.log("\n🔑 Environment Variables Required:");
    console.log("  - SEPOLIA_RPC_URL: Your Ethereum RPC endpoint");
    console.log("  - PRIVATE_KEY: Deployer wallet private key");
    console.log("  - PARASWAP_API_KEY: ParaSwap API key for liquidity");
    console.log("  - ZK_PROVER_URL: Circom prover service URL");
    console.log("  - ZK_VERIFIER_ADDRESS: Groth16 verifier address");
    
    console.log("\n⚠️  SECURITY NOTES:");
    console.log("  - Never commit deployments.json to version control");
    console.log("  - Rotate private keys after deployment");
    console.log("  - Verify contracts on Etherscan before use");
    
    console.log("\n✅ Deployment complete!");
    
  } catch (error) {
    console.error("\n❌ Deployment failed:");
    console.error(error.message);
    
    // Save partial deployment info for debugging
    const errorManifest = {
      network: hre.network.name,
      chainId: hre.network.config.chainId,
      timestamp: Date.now(),
      error: error.message,
      partialDeployments: deployments.map(d => ({
        name: d.name,
        address: d.address
      }))
    };
    
    const deployDir = path.join(__dirname, "..");
    const deployPath = path.join(deployDir, "deployments_error.json");
    fs.writeFileSync(deployPath, JSON.stringify(errorManifest, null, 2));
    console.error(`Error manifest saved to: ${deployPath}`);
    
    process.exit(1);
  }
};

// Run deployment if this is the main module
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

// Export for programmatic use
module.exports = {
  main,
  deployContract,
  generateDeploymentManifest,
  validateEnv
};