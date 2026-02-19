// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";

contract RainfallFunctionsConsumer is FunctionsClient, ConfirmedOwner {
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

    struct RainfallRequest {
        string latitude;
        string longitude;
        string startDate;
        string endDate;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes32 public lastRequestId;
    uint256 public lastRainfallMM;

    mapping(bytes32 => RequestStatus) public requestStatus;
    mapping(bytes32 => uint256) public rainfallByRequest;
    mapping(bytes32 => bytes) public errorByRequest;
    mapping(bytes32 => RainfallRequest) public requestMeta;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnexpectedRequestID(bytes32 requestId);
    error InvalidArgsLength(uint256 length);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RainfallRequested(
        bytes32 indexed requestId, string latitude, string longitude, string startDate, string endDate
    );

    event RainfallResponse(bytes32 indexed requestId, uint256 totalRainfallMM, bytes rawResponse, bytes err);

    /*//////////////////////////////////////////////////////////////
                         CHAINLINK CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address internal constant ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0; // Sepolia

    bytes32 internal constant DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000;

    uint32 internal constant CALLBACK_GAS_LIMIT = 300_000;

    /*//////////////////////////////////////////////////////////////
                        FUNCTIONS SOURCE (JS)
    //////////////////////////////////////////////////////////////*/

    string internal constant SOURCE = "let latitude; let longitude; let startDate; let endDate;"
        "if (typeof args !== \"undefined\" && Array.isArray(args) && args.length >= 4) {" "latitude = String(args[0]);"
        "longitude = String(args[1]);" "startDate = String(args[2]);" "endDate = String(args[3]);" "} else {"
        "throw new Error(\"Missing arguments\");" "}" "const url ="
        "\"https://archive-api.open-meteo.com/v1/archive\" +" "\"?latitude=\" + latitude +"
        "\"&longitude=\" + longitude +" "\"&start_date=\" + startDate +" "\"&end_date=\" + endDate +"
        "\"&daily=precipitation_sum\" +" "\"&timezone=UTC\";" "const response = await Functions.makeHttpRequest({"
        "url: url," "method: \"GET\"," "timeout: 20000" "});" "if (!response || response.error) {"
        "throw new Error(\"Open-Meteo request failed\");" "}"
        "const data = typeof response.data === \"string\" ? JSON.parse(response.data) : response.data;"
        "if (!data || !data.daily || !Array.isArray(data.daily.precipitation_sum)) {"
        "throw new Error(\"Invalid Open-Meteo response\");" "}" "const precipitation = data.daily.precipitation_sum;"
        "let totalRainfallMM = 0;" "for (let i = 0; i < precipitation.length; i++) {" "const v = precipitation[i];"
        "if (typeof v === \"number\" && isFinite(v)) {" "totalRainfallMM += v;" "}" "}"
        "totalRainfallMM = Math.round(totalRainfallMM);" "return Functions.encodeUint256(totalRainfallMM);";

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() FunctionsClient(ROUTER) ConfirmedOwner(msg.sender) {}

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function sendRequest(uint64 subscriptionId, string[] calldata args)
        external
        onlyOwner
        returns (bytes32 requestId)
    {
        if (args.length != 4) {
            revert InvalidArgsLength(args.length);
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(SOURCE);
        req.setArgs(args);

        requestId = _sendRequest(req.encodeCBOR(), subscriptionId, CALLBACK_GAS_LIMIT, DON_ID);

        requestStatus[requestId] = RequestStatus.Pending;
        lastRequestId = requestId;

        requestMeta[requestId] =
            RainfallRequest({latitude: args[0], longitude: args[1], startDate: args[2], endDate: args[3]});

        emit RainfallRequested(requestId, args[0], args[1], args[2], args[3]);
    }

    /*//////////////////////////////////////////////////////////////
                      CHAINLINK FULFILLMENT
    //////////////////////////////////////////////////////////////*/

    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        if (requestStatus[requestId] != RequestStatus.Pending) {
            revert UnexpectedRequestID(requestId);
        }

        if (err.length == 0) {
            uint256 rainfall = abi.decode(response, (uint256));
            rainfallByRequest[requestId] = rainfall;
            lastRainfallMM = rainfall;
            requestStatus[requestId] = RequestStatus.Fulfilled;
        } else {
            errorByRequest[requestId] = err;
            requestStatus[requestId] = RequestStatus.Failed;
        }

        emit RainfallResponse(requestId, rainfallByRequest[requestId], response, err);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get rainfall data for a specific request
     * @param requestId The Chainlink request ID
     * @return rainfall The total rainfall in mm (0 if not fulfilled)
     */
    function getRainfallByRequest(bytes32 requestId) external view returns (uint256 rainfall) {
        return rainfallByRequest[requestId];
    }

    /**
     * @notice Get the status of a specific request
     * @param requestId The Chainlink request ID
     * @return status 0=None, 1=Pending, 2=Fulfilled, 3=Failed
     */
    function getRequestStatus(bytes32 requestId) external view returns (RequestStatus status) {
        return requestStatus[requestId];
    }

    /**
     * @notice Get metadata for a specific request
     * @param requestId The Chainlink request ID
     * @return meta The request metadata (lat, lon, dates)
     */
    function getRequestMeta(bytes32 requestId) external view returns (RainfallRequest memory meta) {
        return requestMeta[requestId];
    }

    /**
     * @notice Check if a request has been fulfilled successfully
     * @param requestId The Chainlink request ID
     * @return fulfilled True if the request is fulfilled
     */
    function isRequestFulfilled(bytes32 requestId) external view returns (bool fulfilled) {
        return requestStatus[requestId] == RequestStatus.Fulfilled;
    }
}
