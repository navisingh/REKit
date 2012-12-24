/*
 REResponder.m
 
 Copyright ©2012 Kazki Miura. All rights reserved.
*/

#import "NSObject+REResponder.h"
#import "REUtil.h"

#if __has_feature(objc_arc)
	#error This code needs compiler option -fno-objc-arc
#endif


// Constants
static NSString* const kClassNamePrefix = @"REResponder";
static NSString* const kProtocolsAssociationKey = @"REResponder_protocols";
static NSString* const kBlocksAssociationKey = @"REResponder_blocks";
static NSString* const kBlockInfosMethodSignatureAssociationKey = @"methodSignature";

// Keys for blockInfo
static NSString* const kBlockInfoBlockKey = @"block";
static NSString* const kBlockInfoBlockNameKey = @"blockName";


@implementation NSObject (REResponder)

//--------------------------------------------------------------//
#pragma mark -- Setup --
//--------------------------------------------------------------//

- (BOOL)REResponder_X_conformsToProtocol:(Protocol*)aProtocol
{
	// original
	if ([self REResponder_X_conformsToProtocol:aProtocol]) {
		return YES;
	}
	
	// Check protocols
	return ([[self associatedValueForKey:kProtocolsAssociationKey][NSStringFromProtocol(aProtocol)] count] > 0);
}

- (BOOL)REResponder_X_respondsToSelector:(SEL)aSelector
{
	// original
	if ([self REResponder_X_respondsToSelector:aSelector]) {
		return YES;
	}
	
	// Check registered selector
	NSString *selectorName;
	selectorName = NSStringFromSelector(aSelector);
	return ([[self associatedValueForKey:kBlocksAssociationKey][selectorName] count] > 0);
}

- (NSMethodSignature*)REResponder_X_methodSignatureForSelector:(SEL)aSelector
{
	// Get selectorName
	NSString *selectorName;
	selectorName = NSStringFromSelector(aSelector);
	
	// Check registered selector
	@synchronized (self) {
		NSMutableArray *blockInfos;
		blockInfos = [self associatedValueForKey:kBlocksAssociationKey][selectorName];
		if (blockInfos) {
			return [blockInfos associatedValueForKey:kBlockInfosMethodSignatureAssociationKey];
		}
	}
	
	// original
	return [self REResponder_X_methodSignatureForSelector:aSelector];
}

- (void)REResponder_X_forwardInvocation:(NSInvocation*)invocation
{
	// Get selectorName
	NSString *selectorName;
	selectorName = NSStringFromSelector([invocation selector]);
	
	// Handle registered selector
	@synchronized (self) {
		// Get blockInfo
		NSDictionary *blockInfo;
		blockInfo = [[self associatedValueForKey:kBlocksAssociationKey][selectorName] lastObject];
		if (!blockInfo) {
			goto ORIGINAL;
		}
		
		// Get elements
		id block;
		NSMethodSignature *methodSignature;
		NSUInteger argc;
		block = blockInfo[kBlockInfoBlockKey];
		if (!block) {
			goto ORIGINAL;
		}
		methodSignature = [invocation methodSignature];
		argc = [methodSignature numberOfArguments];
		
		// Make blockInvocation
		NSInvocation *blockInvocation;
		const char *argType;
		NSUInteger length;
		void *argBuffer;
		NSData *argument;
		blockInvocation = [NSInvocation invocationWithMethodSignature:[NSMethodSignature signatureWithObjCTypes:REBlockGetObjCTypes(block)]];
		[blockInvocation setTarget:block];
		{
			argType = [methodSignature getArgumentTypeAtIndex:0];
			NSGetSizeAndAlignment(argType, &length, NULL);
			
			argBuffer = malloc(length);
			[invocation getArgument:argBuffer atIndex:0];
			
			argument = [NSData dataWithBytesNoCopy:argBuffer length:length];
			[blockInvocation setArgument:(void*)[argument bytes] atIndex:1];
		}
		for (NSInteger i = 2; i < argc; i++) {
			// Get argType and length
			argType = [methodSignature getArgumentTypeAtIndex:i];
			NSGetSizeAndAlignment(argType, &length, NULL);
			
			// Prepare argBuffer
			argBuffer = malloc(length);
			[invocation getArgument:argBuffer atIndex:i];
			
			// Add argument
			argument = [NSData dataWithBytesNoCopy:argBuffer length:length];
			[blockInvocation setArgument:(void*)[argument bytes] atIndex:i];
		}
		
		// Invoke blockInvocation
		[blockInvocation invokeUsingIMP:REBlockGetImplementation(block)];
		
		// Set return value to invocation
		NSUInteger returnLength;
		returnLength = [methodSignature methodReturnLength];
		if (returnLength > 0) {
			// Get return value
			void *returnBuffer;
			returnBuffer = malloc(returnLength);
			[blockInvocation getReturnValue:returnBuffer];
			
			// Set return value
			NSData *returnData;
			static void *returnDataKey;
			returnData = [NSData dataWithBytesNoCopy:returnBuffer length:returnLength];
			[invocation setReturnValue:(void*)returnData.bytes];
			[invocation associateValue:returnData forKey:&returnDataKey policy:OBJC_ASSOCIATION_RETAIN];
		}
		
		return;
	}
	
	// original
	ORIGINAL:
	[self REResponder_X_forwardInvocation:invocation];
}

- (void)REResponder_X_dealloc
{
	// Release protocols
	[self associateValue:nil forKey:kProtocolsAssociationKey policy:OBJC_ASSOCIATION_RETAIN];
	
	// Release blocks
	NSArray *blockNames;
	NSMutableDictionary *blocks;
	blocks = [self associatedValueForKey:kBlocksAssociationKey];
	if ([blocks count]) {
		blockNames = [[blocks allValues] valueForKey:kBlockInfoBlockNameKey];
		blockNames = [blockNames valueForKeyPath:@"@unionOfArrays.self"];
		[blockNames enumerateObjectsUsingBlock:^(NSString *blockName, NSUInteger idx, BOOL *stop) {
			[self removeBlockNamed:blockName];
		}];
		[self associateValue:nil forKey:kBlocksAssociationKey policy:OBJC_ASSOCIATION_RETAIN];
	}
	
	// original
	[self REResponder_X_dealloc];
}

+ (void)load
{
	@autoreleasepool {
		// Exchange instance methods
		[self exchangeInstanceMethodsWithAdditiveSelectorPrefix:@"REResponder_X_" selectors:
			@selector(conformsToProtocol:),
			@selector(methodForSelector:),
			@selector(respondsToSelector:),
			@selector(methodSignatureForSelector:),
			@selector(forwardInvocation:),
			@selector(dealloc),
			nil
		];
	}
}

//--------------------------------------------------------------//
#pragma mark -- Property --
//--------------------------------------------------------------//

- (NSDictionary*)REResponder_blockInfoWithBlockName:(NSString*)blockName blockInfos:(NSMutableArray**)blockInfos selectorName:(NSString**)selectorName
{
	// Get blockInfo
	__block NSDictionary *blockInfo = nil;
	@synchronized (self) {
		[[self associatedValueForKey:kBlocksAssociationKey] enumerateKeysAndObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(NSString *aSelectorName, NSMutableArray *aBlockInfos, BOOL *aStop) {
			[aBlockInfos enumerateObjectsWithOptions:NSEnumerationConcurrent usingBlock:^(NSDictionary *bBlockInfo, NSUInteger bIdx, BOOL *bStop) {
				if ([bBlockInfo[kBlockInfoBlockNameKey] isEqualToString:blockName]) {
					blockInfo = bBlockInfo;
					if (blockInfos) {
						*blockInfos = aBlockInfos;
					}
					if (selectorName) {
						*selectorName = aSelectorName;
					}
					*aStop = YES;
					*bStop = YES;
				}
			}];
		}];
	}
	
	// Nullify inout arguments
	if (!blockInfo) {
		if (blockInfos) {
			*blockInfos = nil;
		}
		if (selectorName) {
			*selectorName = nil;
		}
	}
	
	return blockInfo;
}

//--------------------------------------------------------------//
#pragma mark -- Block --
//--------------------------------------------------------------//

- (void)respondsToSelector:(SEL)selector withBlockName:(NSString*)name usingBlock:(id)block
{
	// Filter
	if (!selector || !block) {
		return;
	}
	
	// Get blockName
	NSString *blockName;
	if ([name length]) {
		blockName = name;
	}
	else {
		blockName = REUUIDString();
	}
	
	// Get selectorName
	NSString *selectorName;
	selectorName = NSStringFromSelector(selector);
	
	// Make signatures
	NSMethodSignature *blockSignature;
	NSMethodSignature *methodSignature;
	NSMutableString *objCTypes;
	blockSignature = [NSMethodSignature signatureWithObjCTypes:REBlockGetObjCTypes(block)];
	objCTypes = [NSMutableString stringWithFormat:@"%@@:", [NSString stringWithCString:[blockSignature methodReturnType] encoding:NSUTF8StringEncoding]];
	for (NSInteger i = 2; i < [blockSignature numberOfArguments]; i++) {
		[objCTypes appendString:[NSString stringWithCString:[blockSignature getArgumentTypeAtIndex:i] encoding:NSUTF8StringEncoding]];
	}
	methodSignature = [NSMethodSignature signatureWithObjCTypes:[objCTypes cStringUsingEncoding:NSUTF8StringEncoding]];
	if (!methodSignature) {
		NSLog(@"Failed to get signature for block named %@", blockName);
		return;
	}
	
	// Update blocks
	[self removeBlockNamed:name];
	@synchronized (self) {
		// Get blocks
		NSMutableDictionary *blocks;
		blocks = [self associatedValueForKey:kBlocksAssociationKey];
		
		// Get blockInfos
		NSMutableArray *blockInfos;
		blockInfos = blocks[selectorName];
		if (!blockInfos) {
			// Make blocks
			if (!blocks) {
				blocks = [NSMutableDictionary dictionary];
				[self associateValue:blocks forKey:kBlocksAssociationKey policy:OBJC_ASSOCIATION_RETAIN];
			}
			
			// Make blockInfos
			blockInfos = [NSMutableArray array];
			[blockInfos associateValue:methodSignature forKey:kBlockInfosMethodSignatureAssociationKey policy:OBJC_ASSOCIATION_RETAIN];
			[blocks setObject:blockInfos forKey:selectorName];
		}
		
		// Replace method
		if ([self REResponder_X_respondsToSelector:selector]) {
			// Become subclass
			if (![NSStringFromClass([self class]) hasPrefix:kClassNamePrefix]) {
				// Update _number
				static NSDecimalNumber *_number = nil;
				if (!_number) {
					_number = [[NSDecimalNumber one] retain];
				}
				else {
					NSDecimalNumber *number;
					number = [_number decimalNumberByAdding:[NSDecimalNumber one]];
					[_number release];
					_number = [number retain];
				}
				
				// Become subclass
				Class originalClass;
				Class subclass;
				NSString *className;
				originalClass = [self class];
				className = [NSString stringWithFormat:@"%@%@_%@", kClassNamePrefix, [_number stringValue], NSStringFromClass([self class])];
				subclass = objc_allocateClassPair(originalClass, [className UTF8String], 0);
				class_addMethod(subclass, selector, NULL, [objCTypes UTF8String]);
				objc_registerClassPair(subclass);
				[self willChangeClass:subclass];
				object_setClass(self, subclass);
				[self didChangeClass:originalClass];
			}
			
			// Replace method
			class_replaceMethod([self class], selector, imp_implementationWithBlock(block), [objCTypes UTF8String]);
		}
		
		// Add blockInfo to blockInfos
		NSDictionary *blockInfo;
		blockInfo = @{
			kBlockInfoBlockKey : Block_copy(block),
			kBlockInfoBlockNameKey : [blockName copy],
		};
		[blockInfos addObject:blockInfo];
	}
}

- (id)blockNamed:(NSString*)blockName
{
	// Get block
	id block;
	@synchronized (self) {
		// Get blockInfo
		NSDictionary *blockInfo;
		blockInfo = [self REResponder_blockInfoWithBlockName:blockName blockInfos:nil selectorName:nil];
		block = blockInfo[kBlockInfoBlockKey];
	}
	
	return block;
}

- (IMP)supermethodOfBlockNamed:(NSString *)blockName
{
	// Filter
	if (![blockName length]) {
		return NULL;
	}
	
	// Get supermethod
	IMP supermethod = NULL;
	@synchronized (self) {
		// Get blockInfo
		NSDictionary *blockInfo;
		NSMutableArray *blockInfos;
		NSString *selectorName;
		SEL selector;
		blockInfo = [self REResponder_blockInfoWithBlockName:blockName blockInfos:&blockInfos  selectorName:&selectorName];
		selector = NSSelectorFromString(selectorName);
		if (blockInfo) {
			// Check index of blockInfo
			NSUInteger index;
			index = [blockInfos indexOfObject:blockInfo];
			if (index == 0) {
				// supermethod is superclass's instance method
				supermethod = [[[self class] superclass] instanceMethodForSelector:selector];
			}
			else {
				// supermethod is superblock's IMP
				id superblock;
				superblock = [blockInfos objectAtIndex:(index - 1)][kBlockInfoBlockKey];
				supermethod = imp_implementationWithBlock(superblock);
			}
		}
	}
	
	return supermethod;
}

- (void)removeBlockNamed:(NSString*)blockName
{
	@synchronized (self) {
		// Get blockInfo and blockInfos
		NSDictionary *blockInfo;
		NSMutableArray *blockInfos;
		NSString *selectorName;
		SEL selector;
		blockInfo = [self REResponder_blockInfoWithBlockName:blockName blockInfos:&blockInfos  selectorName:&selectorName];
		selector = NSSelectorFromString(selectorName);
		if (blockInfo && blockInfos) {
			// Check existance of original method
			if ([self REResponder_X_respondsToSelector:selector]) {
				if (blockInfo == [blockInfos lastObject]) {
					// Replace method
					IMP supermethod;
					supermethod = [self supermethodOfBlockNamed:blockInfo[kBlockInfoBlockNameKey]];
					class_replaceMethod([self class], selector, supermethod, [[[blockInfos associatedValueForKey:kBlockInfosMethodSignatureAssociationKey] objCTypes] UTF8String]);
				}
			}
			
			// Release block
			id block;
			block = blockInfo[kBlockInfoBlockKey];
			if (block) {
				Block_release(block);
			}
			
			// Remove blockInfo
			[blockInfos removeObject:blockInfo];
		}
	}
}

//--------------------------------------------------------------//
#pragma mark -- Conformance --
//--------------------------------------------------------------//

- (void)setConformable:(BOOL)comformable toProtocol:(Protocol*)protocol withKey:(NSString*)key
{
	// Filter
	if (!protocol || ![key length]) {
		return;
	}
	
	// Update REResponder_protocols
	@synchronized (self) {
		// Get elements
		NSString *protocolName;
		NSMutableDictionary *protocols;
		protocolName = NSStringFromProtocol(protocol);
		protocols = [self associatedValueForKey:kProtocolsAssociationKey];
		
		// Add key
		if (comformable) {
			// Associate protocols
			if (!protocols) {
				protocols = [NSMutableDictionary dictionary];
				[self associateValue:protocols forKey:kProtocolsAssociationKey policy:OBJC_ASSOCIATION_RETAIN];
			}
			
			// Get keys
			NSMutableSet *keys;
			keys = protocols[protocolName];
			if (!keys) {
				keys = [NSMutableSet set];
				[protocols setObject:keys forKey:protocolName];
			}
			
			// Add key
			[keys addObject:[key copy]];
		}
		// Remove key
		else {
			// Get keys
			NSMutableSet *keys;
			keys = protocols[protocolName];
			if (![keys count]) {
				return;
			}
			
			// Remove key
			[keys removeObject:key];
			
			// Remove keys
			if (![keys count]) {
				[protocols removeObjectForKey:protocolName];
			}
		}
	}
}

@end
