//
//  OAuth2.swift
//  OAuth2
//
//  Created by Pascal Pfiffner on 6/4/14.
//  Copyright 2014 Pascal Pfiffner
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
#if !NO_MODULE_IMPORT
 import Base
 #if os(OSX)
  import macOS
 #elseif os(iOS)
  import iOS
 #elseif os(tvOS)
  import tvOS
 #endif
#endif


/**
Base class for specific OAuth2 authentication flow implementations.
*/
open class OAuth2: OAuth2Base {
	
	/// If non-nil, will be called before performing dynamic client registration, giving you a chance to instantiate your own registrar.
	public final var onBeforeDynamicClientRegistration: ((URL) -> OAuth2DynReg?)?
	
	/// The authorizer to use for UI handling, depending on platform.
	open var authorizer: OAuth2AuthorizerUI!
	
	
	/**
	Designated initializer.
	
	The following settings keys are currently supported:
	
	- client_id (string)
	- client_secret (string), usually only needed for code grant
	- authorize_uri (URL-string)
	- token_uri (URL-string), if omitted the authorize_uri will be used to obtain tokens
	- redirect_uris (list of URL-strings)
	- scope (string)
	
	- client_name (string)
	- registration_uri (URL-string)
	- logo_uri (URL-string)
	
	- keychain (bool, true by default, applies to using the system keychain)
	- keychain_access_mode (string, value for keychain kSecAttrAccessible attribute, kSecAttrAccessibleWhenUnlocked by default)
	- verbose (bool, false by default, applies to client logging)
	- secret_in_body (bool, false by default, forces the flow to use the request body for the client secret)
	- token_assume_unexpired (bool, true by default, whether to use access tokens that do not come with an "expires_in" parameter)
	- title (string, to be shown in views shown by the framework)
	*/
	override public init(settings: OAuth2JSON) {
		super.init(settings: settings)
		authorizer = OAuth2Authorizer(oauth2: self)
	}
	
	
	// MARK: - Authorization
	
	/**
	Use this method to obtain an access token. Take a look at `authConfig` on how to configure how authorization is presented to the user.
	
	This method is running asynchronously and can only be run one at a time.
	
	This method will first check if the client already has an unexpired access token (possibly from the keychain), if not and it's able to
	use a refresh token it will try to use the refresh token. If this fails it will check whether the client has a client_id and show the
	authorize screen if you have `authConfig` set up sufficiently. If `authConfig` is not set up sufficiently this method will end up
	calling the `onFailure` callback. If client_id is not set but a "registration_uri" has been provided, a dynamic client registration will
	be attempted and if it success, an access token will be requested.
	
	- parameter params:   Optional key/value pairs to pass during authorization and token refresh
	- parameter callback: The callback to call when authorization finishes (parameters will be non-nil but may be an empty dict), fails
	                      (error will be non-nil) or is cancelled (both parameters and error is nil)
	*/
	public final func authorize(params: OAuth2StringDict? = nil, callback: ((OAuth2JSON?, OAuth2Error?) -> Void)) {
		if nil != didAuthorizeOrFail {
			callback(nil, OAuth2Error.alreadyAuthorizing)
			return
		}
		didAuthorizeOrFail = callback
		logger?.debug("OAuth2", msg: "Starting authorization")
		tryToObtainAccessTokenIfNeeded(params: params) { successParams in
			if let successParams = successParams {
				self.didAuthorize(withParameters: successParams)
			}
			else {
				self.registerClientIfNeeded() { json, error in
					if let error = error {
						self.didFail(with: error)
					}
					else {
						do {
							assert(Thread.isMainThread)
							try self.doAuthorize(params: params)
						}
						catch let error {
							self.didFail(with: error.asOAuth2Error)
						}
					}
				}
			}
		}
	}
	
	/**
	This method is deprecated in version 3.0 and has been replaced with `authorize(params:callback:)`.
	
	- parameter params: Optional key/value pairs to pass during authorization and token refresh
	*/
	@available(*, deprecated: 3.0, message: "Use the `authorize(params:callback:)` method and variants")
	public final func authorize(params: OAuth2StringDict? = nil) {
		authorize(params: params) { parameters, error in
		}
	}
	
	/**
	Shortcut function to start embedded authorization from the given context (a UIViewController on iOS, an NSWindow on OS X).
	
	This method sets `authConfig.authorizeEmbedded = true` and `authConfig.authorizeContext = <# context #>`, then calls `authorize()`
	
	- parameter from:     The context to start authorization from, depends on platform (UIViewController or NSWindow, see `authorizeContext`)
	- parameter params:   Optional key/value pairs to pass during authorization
	- parameter callback: The callback to call when authorization finishes (parameters will be non-nil but may be an empty dict), fails
	(error will be non-nil) or is cancelled (both parameters and error is nil)
	*/
	open func authorizeEmbedded(from context: AnyObject, params: OAuth2StringDict? = nil, callback: ((_ authParameters: OAuth2JSON?, _ error: OAuth2Error?) -> Void)) {
		if nil != didAuthorizeOrFail {		// check before changing `authConfig`
			callback(nil, OAuth2Error.alreadyAuthorizing)
			return
		}
		authConfig.authorizeEmbedded = true
		authConfig.authorizeContext = context
		authorize(params: params, callback: callback)
	}
	
	/**
	This method is deprecated in version 3.0 and has been replaced with `authorizeEmbedded(from:params:callback:)`.
	
	- parameter from:    The context to start authorization from, depends on platform (UIViewController or NSWindow, see `authorizeContext`)
	- parameter params:  Optional key/value pairs to pass during authorization
	*/
	@available(*, deprecated: 3.0, message: "Use the `authorize(params:callback:)` method and variants")
	open func authorizeEmbedded(from context: AnyObject, params: OAuth2StringDict? = nil) {
		authorizeEmbedded(from: context, params: params) { parameters, error in
		}
	}
	
	/**
	If the instance has an accessToken, checks if its expiry time has not yet passed. If we don't have an expiry date we assume the token
	is still valid.
	
	- returns: A Bool indicating whether a probably valid access token exists
	*/
	open func hasUnexpiredAccessToken() -> Bool {
		guard let access = accessToken, !access.isEmpty else {
			return false
		}
		if let expiry = accessTokenExpiry {
			return (.orderedDescending == expiry.compare(Date()))
		}
		return clientConfig.accessTokenAssumeUnexpired
	}
	
	/**
	Attempts to receive a new access token by:
	
	1. checking if there still is an unexpired token
	2. attempting to use a refresh token
	
	Indicates, in the callback, whether the client has been able to obtain an access token that is likely to still work (but there is no
	guarantee!) or not.
	
	- parameter params:   Optional key/value pairs to pass during authorization
	- parameter callback: The callback to call once the client knows whether it has an access token or not; if `success` is true an
	                      access token is present
	*/
	open func tryToObtainAccessTokenIfNeeded(params: OAuth2StringDict? = nil, callback: ((OAuth2JSON?) -> Void)) {
		if hasUnexpiredAccessToken() {
			logger?.debug("OAuth2", msg: "Have an apparently unexpired access token")
			callback(OAuth2JSON())
		}
		else {
			logger?.debug("OAuth2", msg: "No access token, checking if a refresh token is available")
			doRefreshToken(params: params) { successParams, error in
				if let successParams = successParams {
					callback(successParams)
				}
				else {
					if let err = error {
						self.logger?.debug("OAuth2", msg: "\(err)")
					}
					callback(nil)
				}
			}
		}
	}
	
	/**
	Method to actually start authorization. The public `authorize()` method only proceeds to this method if there is no valid access token
	and if optional client registration succeeds.
	
	Can be overridden in subclasses to perform an authorization dance different from directing the user to a website.
	
	- parameter params: Optional key/value pairs to pass during authorization
	*/
	open func doAuthorize(params: OAuth2StringDict? = nil) throws {
		if authConfig.authorizeEmbedded {
			try doAuthorizeEmbedded(with: authConfig, params: params)
		}
		else {
			try doOpenAuthorizeURLInBrowser(params: params)
		}
	}
	
	/**
	Open the authorize URL in the OS's browser. Forwards to the receiver's `authorizer`, which is a platform-dependent implementation of
	`OAuth2AuthorizerUI`.
	
	- parameter params: Additional parameters to pass to the authorize URL
	- throws: UnableToOpenAuthorizeURL on failure
	*/
	final func doOpenAuthorizeURLInBrowser(params: OAuth2StringDict? = nil) throws {
		let url = try authorizeURL(params: params)
		logger?.debug("OAuth2", msg: "Opening authorize URL in system browser: \(url)")
		try authorizer.openAuthorizeURLInBrowser(url)
	}
	
	/**
	Tries to use the current auth config context, which on iOS should be a UIViewController and on OS X a NSViewController, to present the
	authorization screen. Set `oauth2.authConfig.authorizeContext` accordingly.
	
	Forwards to the receiver's `authorizer`, which is a platform-dependent implementation of `OAuth2AuthorizerUI`.
	
	- throws:           Can throw OAuth2Error if the method is unable to show the authorize screen
	- parameter with:   The configuration to be used; usually uses the instance's `authConfig`
	- parameter params: Additional authorization parameters to supply during the OAuth dance
	*/
	final func doAuthorizeEmbedded(with config: OAuth2AuthConfig, params: OAuth2StringDict? = nil) throws {
		let url = try authorizeURL(params: params)
		logger?.debug("OAuth2", msg: "Opening authorize URL embedded: \(url)")
		try authorizer.authorizeEmbedded(with: config, at: url)
	}
	
	/**
	Method that creates the OAuth2AuthRequest instance used to create the authorize URL
	
	- parameter redirect: The redirect URI string to supply. If it is nil, the first value of the settings' `redirect_uris` entries is
                          used. Must be present in the end!
	- parameter scope:    The scope to request
	- parameter params:   Any additional parameters as dictionary with string keys and values that will be added to the query part
	- returns:            OAuth2AuthRequest to be used to call to the authorize endpoint
	*/
	func authorizeRequest(withRedirect redirect: String, scope: String?, params: OAuth2StringDict?) throws -> OAuth2AuthRequest {
		guard let clientId = clientConfig.clientId, !clientId.isEmpty else {
			throw OAuth2Error.noClientId
		}
		
		let req = OAuth2AuthRequest(url: clientConfig.authorizeURL, method: .GET)
		req.params["redirect_uri"] = redirect
		req.params["client_id"] = clientId
		req.params["state"] = context.state
		if let scope = scope ?? clientConfig.scope {
			req.params["scope"] = scope
		}
		if let responseType = type(of: self).responseType {
			req.params["response_type"] = responseType
		}
		req.addParams(params: params)
		
		return req
	}
	
	/**
	Most convenient method if you want the authorize URL to be created as defined in your settings dictionary.
	
	- parameter params: Optional, additional URL params to supply to the request
	- returns:          NSURL to be used to start the OAuth dance
	*/
	open func authorizeURL(params: OAuth2StringDict? = nil) throws -> URL {
		return try authorizeURL(withRedirect: nil, scope: nil, params: params)
	}
	
	/**
	Convenience method to be overridden by and used from subclasses.
	
	- parameter redirect: The redirect URI string to supply. If it is nil, the first value of the settings' `redirect_uris` entries is
                          used. Must be present in the end!
	- parameter scope:    The scope to request
	- parameter params:   Any additional parameters as dictionary with string keys and values that will be added to the query part
	- returns:            NSURL to be used to start the OAuth dance
	*/
	open func authorizeURL(withRedirect redirect: String?, scope: String?, params: OAuth2StringDict?) throws -> URL {
		guard let redirect = (redirect ?? clientConfig.redirect) else {
			throw OAuth2Error.noRedirectURL
		}
		let req = try authorizeRequest(withRedirect: redirect, scope: scope, params: params)
		context.redirectURL = redirect
		return try req.asURL()
	}
	
	
	// MARK: - Refresh Token
	
	/**
	Generate the request to be used for token refresh when we have a refresh token.
	
	This will set "grant_type" to "refresh_token", add the refresh token, and take care of the remaining parameters.
	
	- parameter params: Additional parameters to pass during token refresh
	- returns:          An `OAuth2AuthRequest` instance that is configured for token refresh
	*/
	func tokenRequestForTokenRefresh(params: OAuth2StringDict? = nil) throws -> OAuth2AuthRequest {
		guard let clientId = clientId, !clientId.isEmpty else {
			throw OAuth2Error.noClientId
		}
		guard let refreshToken = clientConfig.refreshToken, !refreshToken.isEmpty else {
			throw OAuth2Error.noRefreshToken
		}
		
		let req = OAuth2AuthRequest(url: (clientConfig.tokenURL ?? clientConfig.authorizeURL))
		req.params["grant_type"] = "refresh_token"
		req.params["refresh_token"] = refreshToken
		req.params["client_id"] = clientId
		req.addParams(params: params)
		
		return req
	}
	
	/**
	If there is a refresh token, use it to receive a fresh access token.
	
	- parameter params:   Optional key/value pairs to pass during token refresh
	- parameter callback: The callback to call after the refresh token exchange has finished
	*/
	open func doRefreshToken(params: OAuth2StringDict? = nil, callback: ((OAuth2JSON?, OAuth2Error?) -> Void)) {
		do {
			let post = try tokenRequestForTokenRefresh(params: params).asURLRequest(for: self)
			logger?.debug("OAuth2", msg: "Using refresh token to receive access token from \(post.url?.description ?? "nil")")
			
			perform(request: post) { dataStatusResponse in
				do {
					let (data, status) = try dataStatusResponse()
					let json = try self.parseRefreshTokenResponseData(data)
					if status >= 400 {
						throw OAuth2Error.generic("Failed with status \(status)")
					}
					self.logger?.debug("OAuth2", msg: "Did use refresh token for access token [\(nil != self.clientConfig.accessToken)]")
					callback(json, nil)
				}
				catch let error {
					self.logger?.debug("OAuth2", msg: "Error parsing refreshed access token: \(error)")
					callback(nil, error.asOAuth2Error)
				}
			}
		}
		catch let error {
			callback(nil, error.asOAuth2Error)
		}
	}
	
	
	// MARK: - Registration
	
	/**
	Use OAuth2 dynamic client registration to register the client, if needed.
	
	Returns immediately if the receiver's `clientId` is nil (with error = nil) or if there is no registration URL (with error). Otherwise
	calls `onBeforeDynamicClientRegistration()` -- if it is non-nil -- and uses the returned `OAuth2DynReg` instance -- if it is non-nil.
	If both are nil, instantiates a blank `OAuth2DynReg` instead, then attempts client registration.
	
	- parameter callback: The callback to call on the main thread; if both json and error is nil no registration was attempted; error is nil
	                      on success
	*/
	func registerClientIfNeeded(callback: ((OAuth2JSON?, OAuth2Error?) -> Void)) {
		if nil != clientId {
			callOnMainThread() {
				callback(nil, nil)
			}
		}
		else if let url = clientConfig.registrationURL {
			let dynreg = onBeforeDynamicClientRegistration?(url as URL) ?? OAuth2DynReg()
			dynreg.register(client: self) { json, error in
				callOnMainThread() {
					callback(json, error?.asOAuth2Error)
				}
			}
		}
		else {
			callOnMainThread() {
				callback(nil, OAuth2Error.noRegistrationURL)
			}
		}
	}
}

