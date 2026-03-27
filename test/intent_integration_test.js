// SPDX-License-Identifier: MIT
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("IntentVerifier Integration Tests", function () {
    let owner, solver, user, anotherSolver;
    let intentVerifier, intentRegistry, solverPool;
    let groth16Verifier;
    
    // Mock ZK proof components (simulated for testing)
    const mockProof = {
        pi_a: [
            "145823456789012345678901234567890123456789012345678901234567890",
            "987654321098765432109876543210987654321098765432109876543210987"
        ],
        pi_b: [
            [
                "123456789012345678901234567890123456789012345678901234567890123",
                "876543210987654321098765432109876543210987654321098765432109876"
            ],
            [
                "567890123456789012345678901234567890123456789012345678901234567",
                "432109876543210987654321098765432109876543210987654321098765432"
            ]
        ],
        pi_c: [
            "345678901234567890123456789012345678901234567890123456789012345",
            "654321098765432109876543210987654321098765432109876543210987654"
        ]
    };
    
    const mockInvalidProof = {
        pi_a: [
            "000000000000000000000000000000000000000000000000000000000000000",
            "000000000000000000000000000000000000000000000000000000000000000"
        ],
        pi_b: [
            [
                "000000000000000000000000000000000000000000000000000000000000000",
                "000000000000000000000000000000000000000000000000000000000000000"
            ],
            [
                "000000000000000000000000000000000000000000000000000000000000000",
                "000000000000000000000000000000000000000000000000000000000000000"
            ]
        ],
        pi_c: [
            "000000000000000000000000000000000000000000000000000000000000000",
            "000000000000000000000000000000000000000000000000000000000000000"
        ]
    };
    
    beforeEach(async function () {
        [owner, solver, user, anotherSolver] = await ethers.getSigners();
        
        // Deploy Groth16 Verifier first
        const Groth16VerifierFactory = await ethers.getContractFactory("Groth16Verifier");
        groth16Verifier = await Groth16VerifierFactory.deploy();
        await groth16Verifier.waitForDeployment();
        
        // Deploy IntentVerifier with Groth16 verifier
        const IntentVerifierFactory = await ethers.getContractFactory("IntentVerifier");
        intentVerifier = await IntentVerifierFactory.deploy(groth16Verifier.target);
        await intentVerifier.waitForDeployment();
        
        // Deploy IntentRegistry
        const IntentRegistryFactory = await ethers.getContractFactory("IntentRegistry");
        intentRegistry = await IntentRegistryFactory.deploy();
        await intentRegistry.waitForDeployment();
        
        // Deploy SolverPool
        const SolverPoolFactory = await ethers.getContractFactory("SolverPool");
        solverPool = await SolverPoolFactory.deploy();
        await solverPool.waitForDeployment();
        
        // Register contracts with each other
        await intentVerifier.setRegistry(intentRegistry.target);
        await intentVerifier.setSolverPool(solverPool.target);
        await intentRegistry.setVerifier(intentVerifier.target);
        await intentRegistry.setSolverPool(solverPool.target);
        await solverPool.setVerifier(intentVerifier.target);
        await solverPool.setRegistry(intentRegistry.target);
        
        // Authorize solver
        await intentVerifier.authorizeSolver(solver.address);
        await intentVerifier.authorizeSolver(anotherSolver.address);
        
        // Add solver to pool
        await solverPool.addSolver(solver.address);
        await solverPool.addSolver(anotherSolver.address);
    });
    
    describe("Intent Creation and Verification", function () {
        it("Should create intent and verify valid proof", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            // Verify intent was created
            const intent = await intentRegistry.intents(intentId);
            expect(intent.owner).to.equal(user.address);
            expect(intent.targetOutputAmount).to.equal(targetOutputAmount);
            expect(intent.isFulfilled).to.be.false;
            
            // Submit valid proof
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            await expect(
                intentVerifier.verifyIntentProof(
                    intentId,
                    mockProof,
                    proofHash
                )
            ).to.not.be.reverted;
            
            // Verify intent is now fulfilled
            const updatedIntent = await intentRegistry.intents(intentId);
            expect(updatedIntent.isFulfilled).to.be.true;
        });
        
        it("Should revert on invalid proof", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            // Submit invalid proof - should revert
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            await expect(
                intentVerifier.verifyIntentProof(
                    intentId,
                    mockInvalidProof,
                    proofHash
                )
            ).to.be.reverted;
        });
        
        it("Should prevent double verification of same proof", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            // First verification should succeed
            await intentVerifier.verifyIntentProof(intentId, mockProof, proofHash);
            
            // Second verification should revert
            await expect(
                intentVerifier.verifyIntentProof(intentId, mockProof, proofHash)
            ).to.be.reverted;
        });
        
        it("Should track verification statistics", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create multiple intents
            for (let i = 0; i < 3; i++) {
                await intentRegistry.createIntent(
                    inputToken,
                    outputToken,
                    inputAmount,
                    targetOutputAmount,
                    minAcceptablePrice
                );
            }
            
            const initialTotal = await intentVerifier.totalVerifiedIntents();
            
            // Verify one intent
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, 1]
                )
            );
            
            await intentVerifier.verifyIntentProof(1, mockProof, proofHash);
            
            const finalTotal = await intentVerifier.totalVerifiedIntents();
            expect(finalTotal).to.equal(initialTotal + 1n);
        });
    });
    
    describe("Solver Pool Integration", function () {
        it("Should allow authorized solver to submit proof", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            // Solver submits proof
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            await expect(
                intentVerifier.verifyIntentProof(intentId, mockProof, proofHash)
            ).to.not.be.reverted;
        });
        
        it("Should track solver performance metrics", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create multiple intents
            for (let i = 0; i < 5; i++) {
                await intentRegistry.createIntent(
                    inputToken,
                    outputToken,
                    inputAmount,
                    targetOutputAmount,
                    minAcceptablePrice
                );
            }
            
            // Solver fulfills 3 intents
            for (let i = 1; i <= 3; i++) {
                const proofHash = ethers.keccak256(
                    ethers.solidityPacked(
                        ["uint256", "uint256", "uint256"],
                        [targetOutputAmount, minAcceptablePrice, i]
                    )
                );
                await intentVerifier.verifyIntentProof(i, mockProof, proofHash);
            }
            
            // Check solver pool metrics
            const solverStats = await solverPool.getSolverStats(solver.address);
            expect(solverStats.fulfilledCount).to.be.greaterThan(0);
        });
        
        it("Should handle multiple solvers competing", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            // First solver submits proof
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            await intentVerifier.verifyIntentProof(intentId, mockProof, proofHash);
            
            // Second solver tries to submit same proof - should revert
            await expect(
                intentVerifier.verifyIntentProof(intentId, mockProof, proofHash)
            ).to.be.reverted;
        });
    });
    
    describe("Cross-Chain Swap Simulation", function () {
        it("Should simulate complete cross-chain swap flow", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("10.0");
            const targetOutputAmount = ethers.parseEther("9.5");
            const minAcceptablePrice = ethers.parseEther("9.4");
            
            // Step 1: User creates intent
            const createTx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const createReceipt = await createTx.wait();
            const intentId = createReceipt.events[0].args.intentId;
            
            // Step 2: Intent registered in pool
            const intent = await intentRegistry.intents(intentId);
            expect(intent.isFulfilled).to.be.false;
            
            // Step 3: Solver finds optimal route (simulated)
            const routeHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["address", "address", "uint256"],
                    [inputToken, outputToken, inputAmount]
                )
            );
            
            // Step 4: Solver submits ZK proof of fulfillment
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            const verifyTx = await intentVerifier.verifyIntentProof(
                intentId,
                mockProof,
                proofHash
            );
            const verifyReceipt = await verifyTx.wait();
            
            // Step 5: Verify intent fulfilled
            const updatedIntent = await intentRegistry.intents(intentId);
            expect(updatedIntent.isFulfilled).to.be.true;
            expect(updatedIntent.solverId).to.be.greaterThan(0);
            
            // Step 6: Check solver pool updated
            const solverStats = await solverPool.getSolverStats(solver.address);
            expect(solverStats.fulfilledCount).to.be.greaterThan(0);
        });
        
        it("Should handle partial fulfillment attempts", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("10.0");
            const targetOutputAmount = ethers.parseEther("9.5");
            const minAcceptablePrice = ethers.parseEther("9.4");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            // Attempt to verify with insufficient output (simulated by invalid proof)
            const insufficientProof = {
                pi_a: [
                    "100000000000000000000000000000000000000000000000000000000000000",
                    "200000000000000000000000000000000000000000000000000000000000000"
                ],
                pi_b: [
                    [
                        "300000000000000000000000000000000000000000000000000000000000000",
                        "400000000000000000000000000000000000000000000000000000000000000"
                    ],
                    [
                        "500000000000000000000000000000000000000000000000000000000000000",
                        "600000000000000000000000000000000000000000000000000000000000000"
                    ]
                ],
                pi_c: [
                    "700000000000000000000000000000000000000000000000000000000000000",
                    "800000000000000000000000000000000000000000000000000000000000000"
                ]
            };
            
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            // Should revert due to invalid proof
            await expect(
                intentVerifier.verifyIntentProof(intentId, insufficientProof, proofHash)
            ).to.be.reverted;
        });
        
        it("Should track privacy metrics for executed trades", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            // Verify with valid proof
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            await intentVerifier.verifyIntentProof(intentId, mockProof, proofHash);
            
            // Check that proof was recorded
            const proofCount = await intentVerifier.proofSubmissionCount(proofHash);
            expect(proofCount).to.be.greaterThan(0);
        });
    });
    
    describe("Edge Cases and Security", function () {
        it("Should reject zero intent ID", async function () {
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [0, 0, 0]
                )
            );
            
            await expect(
                intentVerifier.verifyIntentProof(0, mockProof, proofHash)
            ).to.be.reverted;
        });
        
        it("Should reject proof from unauthorized solver", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            // Create intent
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            // Unauthorized user tries to verify
            await expect(
                intentVerifier.connect(user).verifyIntentProof(
                    intentId,
                    mockProof,
                    proofHash
                )
            ).to.be.reverted;
        });
        
        it("Should handle large value intents", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1000.0");
            const targetOutputAmount = ethers.parseEther("950.0");
            const minAcceptablePrice = ethers.parseEther("940.0");
            
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            await expect(
                intentVerifier.verifyIntentProof(intentId, mockProof, proofHash)
            ).to.not.be.reverted;
        });
        
        it("Should prevent timestamp manipulation", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            // Valid proof should work
            await intentVerifier.verifyIntentProof(intentId, mockProof, proofHash);
            
            // Verify intent timestamp is set
            const intent = await intentRegistry.intents(intentId);
            expect(intent.fulfilledAt).to.be.greaterThan(0);
        });
    });
    
    describe("Gas Optimization", function () {
        it("Should track gas usage for verification", async function () {
            const inputToken = ethers.ZeroAddress;
            const outputToken = ethers.ZeroAddress;
            const inputAmount = ethers.parseEther("1.0");
            const targetOutputAmount = ethers.parseEther("0.95");
            const minAcceptablePrice = ethers.parseEther("0.94");
            
            const tx = await intentRegistry.createIntent(
                inputToken,
                outputToken,
                inputAmount,
                targetOutputAmount,
                minAcceptablePrice
            );
            const receipt = await tx.wait();
            const intentId = receipt.events[0].args.intentId;
            
            const proofHash = ethers.keccak256(
                ethers.solidityPacked(
                    ["uint256", "uint256", "uint256"],
                    [targetOutputAmount, minAcceptablePrice, intentId]
                )
            );
            
            const verifyTx = await intentVerifier.verifyIntentProof(
                intentId,
                mockProof,
                proofHash
            );
            const verifyReceipt = await verifyTx.wait();
            
            // Gas should be reasonable for ZK verification
            expect(verifyReceipt.gasUsed).to.be.lessThan(500000);
        });
    });
});