#if defined _steamworks_included
 #endinput
#endif
#define _steamworks_included

enum EHTTPMethod {
    k_EHTTPMethodGET = 1,
    k_EHTTPMethodPOST = 3,
};

enum EHTTPStatusCode {
    k_EHTTPStatusCode200OK = 200,
    k_EHTTPStatusCode201Created = 201,
    k_EHTTPStatusCode401Unauthorized = 401,
    k_EHTTPStatusCode404NotFound = 404,
};

// Handle wrapper
methodmap HTTPRequest < Handle {
    public void SetHeader(const char[] name, const char[] value) {
        SteamWorks_SetHTTPRequestHeaderValue(this, name, value);
    }
}

native Handle SteamWorks_CreateHTTPRequest(EHTTPMethod method, const char[] url);
native bool SteamWorks_SetHTTPRequestContextValue(Handle request, any data);
native bool SteamWorks_SetHTTPRequestNetworkActivityTimeout(Handle request, int timeout);
native bool SteamWorks_SetHTTPRequestHeaderValue(Handle request, const char[] name, const char[] value);
native bool SteamWorks_SetHTTPRequestRawPostBody(Handle request, const char[] contentType, const char[] body, int bodyLen);

// Callback function types
typedef SteamWorksHTTPRequestCompleted = function int (Handle request, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode);

native bool SteamWorks_SetHTTPCallbacks(Handle request, SteamWorksHTTPRequestCompleted completedCallback, Function headersCallback = INVALID_FUNCTION, Function dataCallback = INVALID_FUNCTION);
native bool SteamWorks_SendHTTPRequest(Handle request);
native bool SteamWorks_GetHTTPResponseBodySize(Handle request, int &size);
native bool SteamWorks_GetHTTPResponseBodyData(Handle request, char[] data, int size);
native any SteamWorks_GetHTTPRequestContextValue(Handle request);

public Extension __ext_steamworks = {
	name = "SteamWorks",
	file = "SteamWorks.ext",
#if defined AUTOLOAD_EXTENSIONS
	autoload = 1,
#else
	autoload = 0,
#endif
#if defined REQUIRE_EXTENSIONS
	required = 1,
#else
	required = 0,
#endif
};
