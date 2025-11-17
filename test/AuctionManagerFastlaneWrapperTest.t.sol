// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "lib/atlas/test/base/BaseTest.t.sol";
import "@atlas/contracts/libraries/CallVerification.sol";
import "@atlas/contracts/types/UserOperation.sol";
import "@atlas/contracts/types/SolverOperation.sol";
import "@atlas/contracts/types/DAppOperation.sol";
import "@atlas/contracts/types/AtlasErrors.sol";
import {SolverBase} from "@atlas/contracts/solver/SolverBase.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import {AtlasEvents} from "@atlas/contracts/types/AtlasEvents.sol";
import {SolverOutcome} from "@atlas/contracts/types/EscrowTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import { AuctionManager } from "src/AuctionManager.sol";
import { ChainlinkWrapperEntrypoint } from "src/ChainlinkWrapperEntrypoint.sol";
import { ChainlinkCurvanceOEVWrapper } from "src/ChainlinkCurvanceOEVWrapper.sol";

import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { console2 } from "forge-std/console2.sol";

// Mock Aggregator V3 Interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRound() external view returns (uint256);
}

// Mock Chainlink Feed for testing
contract MockChainlinkFeed is AggregatorV3Interface {
    uint8 public override decimals = 8;
    string public override description = "Mock ETH/USD Feed";
    uint256 public override version = 1;

    uint80 private _latestRoundId = 100;
    int256 private _latestAnswer = 2000e8; // $2000
    uint256 private _latestTimestamp = block.timestamp;

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_latestRoundId, _latestAnswer, _latestTimestamp, _latestTimestamp, _latestRoundId);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _latestAnswer, _latestTimestamp, _latestTimestamp, _roundId);
    }

    function latestRound() external view override returns (uint256) {
        return _latestRoundId;
    }

    // Helper function to update the mock feed
    function setLatestAnswer(int256 newAnswer) external {
        _latestAnswer = newAnswer;
        _latestRoundId++;
        _latestTimestamp = block.timestamp;
    }
}


contract AuctionManagerFastlaneWrapperTest is BaseTest, AtlasErrors, TestBaseMarketIsolated {
    MarketManagerIsolated public unauthorizedMarketManager;
    AuctionManager public auctionManager_;
    ChainlinkWrapperEntrypoint public wrapperEntrypoint;
    ChainlinkCurvanceOEVWrapper public wrapper1;
    ChainlinkCurvanceOEVWrapper public wrapper2;
    MockChainlinkFeed public mockFeed1;
    MockChainlinkFeed public mockFeed2;

    address public collateralToken = address(0xccccccc);

    MockSolver public solver;

    address public constant OEV_ALLOCATION_DESTINATION_FASTLANE = address(0x4111);
    address public constant OEV_ALLOCATION_DESTINATION_PROTOCOL = address(0x5111);
    uint256 public constant OEV_SHARE_BUNDLER = 2000; // 20%
    uint256 public constant OEV_SHARE_FASTLANE = 1000; // 10%
    uint32 public constant SOLVER_GAS_LIMIT = 6_000_000;
    uint256 solverBidAmount = 1 ether;

    uint256 auctioneerPK = 0xabcdef;
    address auctioneer = vm.addr(auctioneerPK);

    uint256 userOpSignerPK = 0x123456;
    address userOpSigner = vm.addr(userOpSignerPK);

    uint256 bundlerPK = 0x234567;
    address bundler = vm.addr(bundlerPK);

    function setUp() public override(BaseTest, TestBaseMarketIsolated) {
        // Initialize Curvance test harness
        TestBaseMarketIsolated.setUp();

        // Initialize Atlas test harness
        __createAndLabelAccounts();
        __deployAtlasContracts();
        __fundSolversAndDepositAtlETH();

        vm.startPrank(centralRegistry.daoAddress());

        _prepareDAI(centralRegistry.daoAddress(), 77777 * 2);
        _prepareUSDC(centralRegistry.daoAddress(), 77777 * 2);
        dai.approve(address(borrowableCDAI), 77777);
        usdc.approve(address(borrowableCUSDC), 77777);
        marketManagerIsolated.listTokens(address(borrowableCDAI), address(borrowableCUSDC));
        _setCTokenConfigBasic(address(borrowableCDAI), 1_000_000e18, 1_000_000e18);
        _setCTokenConfigBasic(address(borrowableCUSDC), 1_000_000e6, 1_000_000e6);

        unauthorizedMarketManager = new MarketManagerIsolated(
            ICentralRegistry(address(centralRegistry)),
            10e18, // minLoanSize
            true // isCorrelatedMarket
        );

        vm.stopPrank();

        vm.startPrank(governanceEOA);

        auctionManager_ = new AuctionManager(
            address(atlas),
            ICentralRegistry(address(centralRegistry)),
            OEV_SHARE_FASTLANE,
            OEV_ALLOCATION_DESTINATION_FASTLANE,
            OEV_ALLOCATION_DESTINATION_PROTOCOL
        );

        auctionManager_.setAuthorizedUserOpSigner(userOpSigner);
        atlasVerification.initializeGovernance(address(auctionManager_));
        atlasVerification.addSignatory(address(auctionManager_), auctioneer);

        vm.stopPrank();

        vm.startPrank(governanceEOA);
        address executionEnv = auctionManager_.authorizedExecutionEnv();
        vm.startPrank(centralRegistry.emergencyCouncil());
        centralRegistry.addAuctionPermissions(executionEnv);
        centralRegistry.addAuctionPermissions(address(auctionManager_));
        vm.stopPrank();

        // Deploy mock Chainlink feeds and real wrappers
        mockFeed1 = new MockChainlinkFeed();
        mockFeed2 = new MockChainlinkFeed();

        wrapper1 = new ChainlinkCurvanceOEVWrapper(
            address(mockFeed1),
            governanceEOA,
            3, // maxDecrements
            10 // maxRoundDelay
        );

        wrapper2 = new ChainlinkCurvanceOEVWrapper(
            address(mockFeed2),
            governanceEOA,
            3, // maxDecrements
            10 // maxRoundDelay
        );

        // Deploy the wrapper entrypoint
        wrapperEntrypoint = new ChainlinkWrapperEntrypoint(governanceEOA);

        vm.startPrank(governanceEOA);

        // Configure wrappers in the entrypoint
        wrapperEntrypoint.configureWrapper(address(wrapper1), true);
        wrapperEntrypoint.configureWrapper(address(wrapper2), true);

        // Whitelist the wrapper entrypoint as an oracle
        auctionManager_.addAllowedRoute(address(wrapperEntrypoint), ChainlinkWrapperEntrypoint.batchUpdatePriceEarly.selector);

        // Whitelist the AuctionManager in both wrappers
        wrapper1.setWhitelist(address(wrapperEntrypoint), true);
        wrapper2.setWhitelist(address(wrapperEntrypoint), true);

        vm.stopPrank();

        // Deploy solver
        vm.deal(solverOneEOA, 10 ether);
        vm.startPrank(solverOneEOA);
        solver = new MockSolver(WETH_ADDRESS, address(atlas));
        vm.deal(address(solver), 10 * solverBidAmount);
        atlas.depositAndBond{value: 5 ether}(5 ether);
        vm.stopPrank();

        collateralToken = address(borrowableCUSDC);
    }

    function testFastlaneWrapper_batchUpdatePriceEarly() public {
        // Update the mock feeds to have new rounds
        mockFeed1.setLatestAnswer(2100e8); // New price and increments roundId to 101
        mockFeed2.setLatestAnswer(1800e8); // New price and increments roundId to 101

        UserOperation memory userOp = buildUserOperation(userOpSignerPK);

        SolverOperation memory solverOp = buildSolverOperation(
            solverOnePK,
            address(solver),
            atlasVerification.getUserOperationHash(userOp),
            solverBidAmount,
            collateralToken,
            address(marketManagerIsolated),
            false
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dappOp =
            buildDAppOperation(atlasVerification.getUserOperationHash(userOp), callChainHash, bundler);

        vm.deal(bundler, 2 ether);
        vm.txGasPrice(1 gwei);

        // Expect PriceUpdatedEarly events from both wrappers
        vm.expectEmit(true, true, false, true, address(wrapper1));
        emit ChainlinkCurvanceOEVWrapper.PriceUpdatedEarly(address(wrapperEntrypoint), 101);

        vm.expectEmit(true, true, false, true, address(wrapper2));
        emit ChainlinkCurvanceOEVWrapper.PriceUpdatedEarly(address(wrapperEntrypoint), 101);

        vm.startBroadcast(bundlerPK);

        (bool success,) = address(atlas).call{gas: 21_100_000}(
            abi.encodeWithSelector(atlas.metacall.selector, userOp, solverOps, dappOp, address(0))
        );

        vm.stopBroadcast();

        assertTrue(success, "metacall should succeed");

        // Verify both wrappers were updated
        assertEq(wrapper1.cachedRoundId(), 101, "Wrapper1 should have updated round ID");
        assertEq(wrapper2.cachedRoundId(), 101, "Wrapper2 should have updated round ID");
    }

    function buildUserOperation(uint256 signerPK) internal view returns (UserOperation memory userOp) {
        // Encode the batch update call with the entrypoint's batchUpdatePriceEarly
        bytes memory updateCallData = abi.encodeWithSelector(ChainlinkWrapperEntrypoint.batchUpdatePriceEarly.selector);

        userOp = UserOperation({
            from: vm.addr(signerPK),
            to: address(atlas),
            value: 0,
            gas: 1_000_000,
            maxFeePerGas: 1 gwei,
            nonce: 1,
            deadline: block.number + 2,
            dapp: address(auctionManager_),
            control: address(auctionManager_),
            callConfig: auctionManager_.CALL_CONFIG(),
            dappGasLimit: 2_000_000,
            solverGasLimit: SOLVER_GAS_LIMIT,
            bundlerSurchargeRate: 1000,
            sessionKey: address(auctioneer),
            data: abi.encodeWithSelector(
                auctionManager_.update.selector,
                address(wrapperEntrypoint),
                updateCallData
            ),
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(signerPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return userOp;
    }

    function buildSolverOperation(
        uint256 solverPK,
        address solverContract,
        bytes32 userOpHash,
        uint256 bidAmount,
        address collateral,
        address market,
        bool isReverting
    ) internal view returns (SolverOperation memory) {
        bytes memory data;
        if (isReverting) {
            data = abi.encodeWithSelector(solver.solveRevert.selector, collateral, market);
        } else {
            data = abi.encodeWithSelector(solver.solve.selector, collateral, market);
        }

        address solverEoa = vm.addr(solverPK);
        SolverOperation memory solverOp = SolverOperation({
            from: solverEoa,
            to: address(atlas),
            value: 0,
            gas: SOLVER_GAS_LIMIT,
            maxFeePerGas: 1 gwei,
            deadline: block.number + 100,
            solver: solverContract,
            control: address(auctionManager_),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: bidAmount,
            data: data,
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return solverOp;
    }

    function buildDAppOperation(bytes32 userOpHash, bytes32 callChainHash, address givenBundler)
        internal
        view
        returns (DAppOperation memory)
    {
        DAppOperation memory dappOp = DAppOperation({
            from: address(auctioneer),
            to: address(atlas),
            nonce: 0,
            deadline: block.number + 2,
            control: address(auctionManager_),
            bundler: givenBundler,
            userOpHash: userOpHash,
            callChainHash: callChainHash,
            signature: new bytes(0)
        });

        Sig memory sig;
        (sig.v, sig.r, sig.s) = vm.sign(auctioneerPK, atlasVerification.getDAppOperationPayload(dappOp));
        dappOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);
        return dappOp;
    }
}

// Mock solver contract
contract MockSolver is SolverBase {
    fallback() external payable {}
    receive() external payable {}

    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) {}

    function solve(address collateral, address market) external pure {
        // Mock function - intentionally empty
    }

    function solveRevert(address collateral, address market) external pure {
        revert("Atlas OEV is not allowed");
    }
}
