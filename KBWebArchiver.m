//
//  KBWebArchiver.m (patched by John Winter)
//  ---------------
//
//  Orginal : Keith Blount 2005
//	Page timeout fix: John Winter 2006
//  Keith Blount 2008
//  Code Cleanup: Jan Weiß 2011
//

#import "KBWebArchiver.h"

#import "NSURL+ValidityChecking.h"


@interface KBWebArchiver (Private)
- (void)getWebPage;
@end

@implementation KBWebArchiver

@synthesize URL = _URL;
@synthesize localResourceLoadingOnly;

- (id)initWithURLString:(NSString *)aURLString isFilePath:(BOOL)flag
{
	NSURL *aURL;	
	
	if (aURLString == nil)
	{
		aURL = nil;
	}
	else
	{
		aURL = (flag ? [NSURL fileURLWithPath:aURLString] : [NSURL URLWithString:aURLString]);
	}
	
	return [self initWithURL:aURL];
}

- (id)initWithURLString:(NSString *)aURLString
{
	NSURL *aURL;	
	
	if (aURLString == nil)
	{
		aURL = nil;
	}
	else 
	{
		aURL = [NSURL URLWithString:aURLString];
	}
	
	if (aURL && aURL.scheme) {
		return [self initWithURL:aURL];
	}
	else {
		return [self initWithURLString:aURLString isFilePath:YES];
	}
}

- (id)initWithURL:(NSURL *)aURL
{
	self = [super init];
	
	if (self)
	{
		_URL = [aURL retain];
		archiveInformation = nil;
		localResourceLoadingOnly = NO;
	}
	return self;
}

- (id)init
{
	return [self initWithURL:nil];
}

- (void)dealloc
{
	[_URL release];
	[archiveInformation release];
	
	[super dealloc];
}

- (void)setURLString:(NSString *)aURLString isFilePath:(BOOL)isFilePath
{
	self.URL = (isFilePath ? [[NSURL alloc] initFileURLWithPath:aURLString] : [[NSURL alloc] initWithString:aURLString]);
}

- (NSString *)URLString
{
	return ([_URL isFileURL] ? [_URL path] : [_URL absoluteString]);
}

- (BOOL)isFilePath
{
	return [_URL isFileURL];
}

- (WebArchive *)webArchive
{
	// If we changed the URL since the last time we checked, then (re)generate the web archive information.
	if ([_URL isEqual:[archiveInformation objectForKey:@"URL"]] == NO)
		[self getWebPage];

	return [archiveInformation objectForKey:@"WebArchive"];
}

- (NSString *)string
{
	// If we changed the URL since the last time we checked, then (re)generate the web archive information.
	if ([_URL isEqual:[archiveInformation objectForKey:@"URL"]] == NO)
		[self getWebPage];

	return [archiveInformation objectForKey:@"String"];
}

- (NSString *)title
{
	// If we changed the URL since the last time we checked, then (re)generate the web archive information.
	if ([_URL isEqual:[archiveInformation objectForKey:@"URL"]] == NO)
		[self getWebPage];

	return [archiveInformation objectForKey:@"Title"];
}

- (NSError *)error
{
	// If we changed the URL since the last time we checked, then we have no error to report.
	if ([_URL isEqual:[archiveInformation objectForKey:@"URL"]] == NO)
		return nil;
	
	return [[[archiveInformation objectForKey:@"Error"] retain] autorelease];
}

- (void)getWebPage
{
	[archiveInformation release];
	archiveInformation = [[NSMutableDictionary alloc] init];
	
	if (_URL == nil)
	{
		//NSBeep();
		NSLog (@"*** KBWebArchiver error: No URL passed in. ***");
		return;
	}
	
	// Add the URL.
	[archiveInformation setObject:_URL forKey:@"URL"];
	
	// We also set a default title for the web page - if all goes well, this will be changed to something more
	// meaningful in -webView:didReceiveTitle:forFrame:.
	[archiveInformation setObject:NSLocalizedString(@"Web Page", nil) forKey:@"Title"];
	
	// Check the URL is valid if it is to be downloaded from the 'net.
	if ([_URL isFileURL] == NO && [_URL httpIsValid] == NO)
	{
		NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
		[userInfo setObject:NSLocalizedString(@"Invalid URL", @"") forKey:NSLocalizedDescriptionKey];
		[userInfo setObject:NSLocalizedString(@"The URL was invalid and so could not be converted to a web archive.",nil) forKey:NSLocalizedRecoverySuggestionErrorKey];
		[archiveInformation setObject:[NSError errorWithDomain:@"" code:0 userInfo:userInfo] forKey:@"Error"];
		
		return;
	}
	
	// We have to create a web view, load the web page into this web view, and then grab the web archive and information from there.
	WebView *webView = [[WebView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)];
	[webView setFrameLoadDelegate:self];
	[webView setResourceLoadDelegate:self];
	[webView setPolicyDelegate:self];
	
	NSError *localLoadingError = nil;
	BOOL tryLocalLoad = NO;
	
	while (1) {
		finishedLoading = NO;
		loadFailed = NO;
		
		if (!tryLocalLoad)
		{
			// Set up the load request and try to load the page.
			NSURLRequestCachePolicy cachePolicy;
#if (MAC_OS_X_VERSION_MIN_REQUIRED < 1050)	
			cachePolicy = NSURLRequestReloadIgnoringCacheData;
#else
			cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
#endif
			
			NSURLRequest *theRequest = [NSURLRequest requestWithURL:_URL
														cachePolicy:cachePolicy
													timeoutInterval:30];
			
			[[webView mainFrame] loadRequest:theRequest];
		}
		else
		{
			// Falling back to loading data from local file
			NSData *data = [NSData dataWithContentsOfURL:_URL
												 options:0 
												   error:&localLoadingError];
			if (data != nil)
			{
				[[webView mainFrame] loadData:data 
									 MIMEType:@"text/html" // CHANGEME: Assuming html
							 textEncodingName:@"UTF-8" // CHANGEME: Assuming UTF8
									  baseURL:_URL];
			}
			else
			{
				[archiveInformation setObject:localLoadingError forKey:@"Error"];
				break;
			}
		}
		
		// Wait until the site has finished loading.
		NSTimeInterval resolution = 1.0;
		BOOL isRunning;
		
		do {
			NSDate* next = [NSDate dateWithTimeIntervalSinceNow:resolution]; 
			isRunning = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:next];
		} while (isRunning && finishedLoading == NO);
		
		[[webView mainFrame] stopLoading];	// Ensure the frame stops loading, otherwise will crash when released!
		
		if (!tryLocalLoad
			&& loadFailed 
			&& [_URL isFileURL]
			&& ((localLoadingError = [archiveInformation objectForKey:@"Error"]) != nil)
			&& ([localLoadingError code] == 102)) // Frame load interrupted
		{
			// This can occur if the local file we are trying to load is missing its extension (usually “.html”)
			tryLocalLoad = YES;
			[archiveInformation removeObjectForKey:@"Error"];
			continue;
		}
		else
		{
			break;
		}
	}
	
	[webView setFrameLoadDelegate:nil];
	[webView setResourceLoadDelegate:nil];
	[webView setPolicyDelegate:nil];
	
	// If the load failed, don't set any more data - just return.
	if (loadFailed)
	{
		[webView release];
		
		if ([archiveInformation objectForKey:@"Error"] == nil)
		{
			NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
			[userInfo setObject:NSLocalizedString(@"Web Page Failed to Load", @"") forKey:NSLocalizedDescriptionKey];
			[userInfo setObject:NSLocalizedString(@"The web page at the given URL failed to load and so could not be converted to a WebArchive.",nil) forKey:NSLocalizedRecoverySuggestionErrorKey];
			[archiveInformation setObject:[NSError errorWithDomain:@"" code:0 userInfo:userInfo] forKey:@"Error"];
		}
		
		return;
	}
	
	// Get the text if the web view has any.
	NSString *string = @"";
	if ([[[[webView mainFrame] frameView] documentView] conformsToProtocol:@protocol(WebDocumentText)])
		string = [(id <WebDocumentText>)[[[webView mainFrame] frameView] documentView] string];
	
	[archiveInformation setObject:string forKey:@"String"];
	
	// the -dataSource method was causing some crashes and also some web pages only half-loaded;
	// using the -DOMDocument method seems to work much better.
	
	//WebArchive *webArchive = [[[webView mainFrame] dataSource] webArchive];
	WebArchive *webArchive = [[[webView mainFrame] DOMDocument] webArchive];
	if (webArchive)
	{
		[archiveInformation setObject:webArchive forKey:@"WebArchive"];
	}
	else if ([archiveInformation objectForKey:@"Error"] == nil)
	{
		NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
		[userInfo setObject:NSLocalizedString(@"Web Archive Creation Failed", @"") forKey:NSLocalizedDescriptionKey];
		[userInfo setObject:NSLocalizedString(@"A web archive could not be created from the page at the given URL.",nil) forKey:NSLocalizedRecoverySuggestionErrorKey];
		[archiveInformation setObject:[NSError errorWithDomain:@"" code:0 userInfo:userInfo] forKey:@"Error"];
	}

	
	[webView release];
}

// Oh dear, this can cause some crashes - eg. importing Yahoo...

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
	if (frame == [sender mainFrame])
		finishedLoading = YES;
}

// Check for errors loading page
- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
	if (frame == [sender mainFrame])
	{
		loadFailed = YES;
		finishedLoading = YES;
		if (error)
			[archiveInformation setObject:error forKey:@"Error"];
	}
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame
{
	if (frame == [sender mainFrame])
	{
		// UPDATE: Some pages automatically report being cancelled and fail even though they load,
		// so in this case we don't want to finish loading but we do want store the error.
		if ([error code] != NSURLErrorCancelled)
		{
			loadFailed = YES;
			finishedLoading = YES;
		}
		
		if (error)
			[archiveInformation setObject:error forKey:@"Error"];
	}
}

// Get the title
- (void)webView:(WebView *)sender didReceiveTitle:(NSString *)title forFrame:(WebFrame *)frame
{
   if (frame == [sender mainFrame] && title != nil)
	   [archiveInformation setObject:title forKey:@"Title"];
}

// This method handles loading web archives - without this, a lot of web archives will not load...
- (void)webView:(WebView *)sender decidePolicyForMIMEType:(NSString *)type request:(NSURLRequest *)request frame:(WebFrame *)frame decisionListener:(id<WebPolicyDecisionListener>)listener
{
	if ([WebView canShowMIMEType:type])
	{
		[listener use];
		return;
	}
	
	[listener ignore];
}


- (NSURLRequest *)webView:(WebView *)sender resource:(id)identifier willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse fromDataSource:(WebDataSource *)dataSource
{
	if (!localResourceLoadingOnly 
		|| (localResourceLoadingOnly && [[[request URL] scheme] isEqualToString:@"file"]))
	{
		return request;
	} else {
		return nil;
	}
}

@end
