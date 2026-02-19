// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

/**
 * @title PremiumCalculatorConsumer
 * @notice Chainlink Functions consumer for calculating option premiums
 * @dev Uses 10 years of historical data to calculate fair premiums
 */
contract PremiumCalculatorConsumer is FunctionsClient, ConfirmedOwner {
    using FunctionsRequest for FunctionsRequest.Request;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    enum RequestStatus {
        None,
        Pending,
        Fulfilled,
        Failed
    }

    struct PremiumRequest {
        string latitude;
        string longitude;
        uint256 strikeMM;
        uint256 spreadMM;
        uint256 durationDays;
        uint256 notionalWei;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    // Chainlink configuration
    bytes32 public donId;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit;

    // Request tracking
    mapping(bytes32 => RequestStatus) public requestStatus;
    mapping(bytes32 => uint256) public premiumByRequest;
    mapping(bytes32 => PremiumRequest) public requestMeta;
    mapping(bytes32 => bytes) public errorByRequest;

    bytes32 public lastRequestId;
    uint256 public lastPremium;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnexpectedRequestID(bytes32 requestId);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PremiumRequested(
        bytes32 indexed requestId,
        string latitude,
        string longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    );

    event PremiumFulfilled(bytes32 indexed requestId, uint256 premiumWei);

    event RequestFailed(bytes32 indexed requestId, bytes err);

    /*//////////////////////////////////////////////////////////////
                         JAVASCRIPT SOURCE
    //////////////////////////////////////////////////////////////*/

    string internal constant SOURCE =
        "let latitude, longitude, strikeRainfall, spreadRainfall, durationDays, notionalWei;"
        "if (typeof args !== 'undefined' && args && args.length >= 6) {"
        "latitude = args[0]; longitude = args[1]; strikeRainfall = parseInt(args[2]);"
        "spreadRainfall = parseInt(args[3]); durationDays = parseInt(args[4]);" "notionalWei = BigInt(args[5]);"
        "} else { throw new Error('Missing arguments'); }" "const today = new Date();"
        "const endDate = today.toISOString().split('T')[0];"
        "const tenYearsAgo = new Date(today.getTime() - 10 * 365 * 24 * 60 * 60 * 1000);"
        "const startDate = tenYearsAgo.toISOString().split('T')[0];"
        "const url = `https://archive-api.open-meteo.com/v1/archive?latitude=${latitude}&longitude=${longitude}&start_date=${startDate}&end_date=${endDate}&daily=precipitation_sum&timezone=UTC`;"
        "const response = await Functions.makeHttpRequest({ url: url, method: 'GET', timeout: 30000 });"
        "if (response.error) { throw new Error('Open-Meteo request failed'); }" "const data = response.data;"
        "if (!data || !data.daily || !Array.isArray(data.daily.precipitation_sum)) {"
        "throw new Error('Invalid Open-Meteo response');" "}" "const dailyPrecipitation = data.daily.precipitation_sum;"
        "const periodSums = [];" "for (let i = 0; i <= dailyPrecipitation.length - durationDays; i++) {"
        "let periodSum = 0; let validDays = 0;" "for (let j = 0; j < durationDays; j++) {"
        "const value = dailyPrecipitation[i + j];" "if (typeof value === 'number' && isFinite(value)) {"
        "periodSum += value; validDays++;" "}" "}" "if (validDays === durationDays) { periodSums.push(periodSum); }" "}"
        "if (periodSums.length === 0) { throw new Error('No valid historical periods'); }" "let totalPayout = 0;"
        "for (let i = 0; i < periodSums.length; i++) {" "const rainfall = periodSums[i];"
        "if (rainfall > strikeRainfall) {" "const excess = rainfall - strikeRainfall;"
        "totalPayout += Math.min(excess, spreadRainfall);" "}" "}"
        "const expectedPayoutMM = totalPayout / periodSums.length;"
        "const expectedPayoutWei = BigInt(Math.round(expectedPayoutMM * 1000)) * notionalWei / 1000n;"
        "let riskMultiplier = 150;" "if (periodSums.length < 1000) { riskMultiplier = 170; }"
        "if (periodSums.length < 500) { riskMultiplier = 200; }"
        "const premiumWei = (expectedPayoutWei * BigInt(riskMultiplier)) / 100n;"
        "return Functions.encodeUint256(Number(premiumWei));";

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address router, bytes32 _donId, uint64 _subscriptionId, uint32 _callbackGasLimit)
        FunctionsClient(router)
        ConfirmedOwner(msg.sender)
    {
        donId = _donId;
        subscriptionId = _subscriptionId;
        callbackGasLimit = _callbackGasLimit;
    }

    /*//////////////////////////////////////////////////////////////
                          REQUEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function requestPremium(
        string calldata latitude,
        string calldata longitude,
        uint256 strikeMM,
        uint256 spreadMM,
        uint256 durationDays,
        uint256 notionalWei
    ) external onlyOwner returns (bytes32 requestId) {
        string[] memory args = new string[](6);
        args[0] = latitude;
        args[1] = longitude;
        args[2] = _uint2str(strikeMM);
        args[3] = _uint2str(spreadMM);
        args[4] = _uint2str(durationDays);
        args[5] = _uint2str(notionalWei);

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(SOURCE);
        req.setArgs(args);

        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, donId);

        requestStatus[requestId] = RequestStatus.Pending;
        lastRequestId = requestId;

        requestMeta[requestId] = PremiumRequest({
            latitude: latitude,
            longitude: longitude,
            strikeMM: strikeMM,
            spreadMM: spreadMM,
            durationDays: durationDays,
            notionalWei: notionalWei
        });

        emit PremiumRequested(requestId, latitude, longitude, strikeMM, spreadMM, durationDays, notionalWei);
    }

    /*//////////////////////////////////////////////////////////////
                      CHAINLINK FULFILLMENT
    //////////////////////////////////////////////////////////////*/

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (requestStatus[requestId] != RequestStatus.Pending) {
            revert UnexpectedRequestID(requestId);
        }

        if (err.length == 0) {
            uint256 premium = abi.decode(response, (uint256));
            premiumByRequest[requestId] = premium;
            lastPremium = premium;
            requestStatus[requestId] = RequestStatus.Fulfilled;

            emit PremiumFulfilled(requestId, premium);
        } else {
            errorByRequest[requestId] = err;
            requestStatus[requestId] = RequestStatus.Failed;

            emit RequestFailed(requestId, err);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getPremiumByRequest(bytes32 requestId) external view returns (uint256) {
        return premiumByRequest[requestId];
    }

    function getRequestStatus(bytes32 requestId) external view returns (RequestStatus) {
        return requestStatus[requestId];
    }

    function isRequestFulfilled(bytes32 requestId) external view returns (bool) {
        return requestStatus[requestId] == RequestStatus.Fulfilled;
    }

    function getRequestMeta(bytes32 requestId) external view returns (PremiumRequest memory) {
        return requestMeta[requestId];
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function updateSubscriptionId(uint64 _subscriptionId) external onlyOwner {
        subscriptionId = _subscriptionId;
    }

    function updateCallbackGasLimit(uint32 _callbackGasLimit) external onlyOwner {
        callbackGasLimit = _callbackGasLimit;
    }

    function updateDonId(bytes32 _donId) external onlyOwner {
        donId = _donId;
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
