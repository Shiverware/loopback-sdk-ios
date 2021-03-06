/**
 * @file LBModel.m
 *
 * @author Michael Schoonmaker
 * @copyright (c) 2013 StrongLoop. All rights reserved.
 */

#import <objc/runtime.h>

#import "LBModel.h"
#import "LBRESTAdapter.h"

@interface LBModel() {
    NSMutableDictionary *__overflow;
}

- (NSMutableDictionary *)_overflow;

@end


@implementation LBModel

- (instancetype)initWithRepository:(SLRepository *)repository parameters:(NSDictionary *)parameters {
    self = [super initWithRepository:repository parameters:parameters];

    if (self) {
        __overflow = [NSMutableDictionary dictionary];
    }

    return self;
}

- (id)objectForKeyedSubscript:(id <NSCopying>)key {
    return [__overflow objectForKey:key];
}

- (void)setObject:(id)obj forKeyedSubscript:(id <NSCopying>)key {
    [__overflow setObject:obj forKey:key];
}

- (NSMutableDictionary *)_overflow {
    return __overflow;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithDictionary:__overflow];

    for (Class targetClass = [self class]; targetClass != [LBModel superclass]; targetClass = [targetClass superclass]) {
        unsigned int propertyCount;
        objc_property_t *properties = class_copyPropertyList(targetClass, &propertyCount);

        for (int i = 0; i < propertyCount; i++) {
          NSString *propertyName = [NSString stringWithCString:property_getName(properties[i])
                                                      encoding:NSUTF8StringEncoding];
          
          // Do not send model getter 'id' fields as creation parameters
          if([propertyName isEqualToString:@"id"]) {
            continue;
          }
          
          id obj = [self valueForKey:propertyName];
          
          // Setting a model parameter to nil should set it to null on the server EXCEPT for read-only properties date and GPS pointLocation
          // Do not overwrite default parameters set by the server by sending an explicit null; createdAt and updatedAt should never be set and always maintained by the server
          if (obj == nil && ![propertyName isEqualToString:@"createdAt"] && ![propertyName isEqualToString:@"updatedAt"] && ![propertyName isEqualToString:@"pointLocation"]) {
            obj = [NSNull null];
          }
          
          [dict setValue:obj forKey:propertyName];
        }
        free(properties);
    }

    return dict;
}

- (NSString *)description {
    return [NSString stringWithFormat: @"<%@ %@>", NSStringFromClass([self class]), [self toDictionary]];
}

@end

@implementation LBModelRepository

- (instancetype)initWithClassName:(NSString *)name {
    self = [super initWithClassName:name];

    if (self) {
        NSString *modelClassName = NSStringFromClass([self class]);
        const int strlenOfRepository = 10;
        modelClassName = [modelClassName substringWithRange:NSMakeRange(0, [modelClassName length] - strlenOfRepository)];

        self.modelClass = NSClassFromString(modelClassName);
        if (!self.modelClass) {
            self.modelClass = [LBModel class];
        }
    }

    return self;
}

- (SLRESTContract *)contract {
    SLRESTContract *contract = [SLRESTContract contract];
    return contract;
}

- (LBModel *)model {
    LBModel *model = (LBModel *)[[self.modelClass alloc] initWithRepository:self parameters:nil];
    return model;
}

- (LBModel *)modelWithDictionary:(NSDictionary *)dictionary {
    LBModel *model = (LBModel *)[[self.modelClass alloc] initWithRepository:self parameters:dictionary];

    [[model _overflow] addEntriesFromDictionary:dictionary];

    for (Class targetClass = [model class]; targetClass != [LBModel superclass]; targetClass = [targetClass superclass]) {
        unsigned int count;
        objc_property_t* props = class_copyPropertyList(targetClass, &count);
        for (int i = 0; i < count; i++) {
            objc_property_t property = props[i];
            const char *name = property_getName(property);
          
            NSMutableString *nameString = [NSMutableString stringWithUTF8String:name];
          
            // Provide workaround for the situation of a model having a "description" field. Description
            // is already used by NSObjectProtocol so it cannot be a LBPersistedModel parameter.
            // This provides an alternate mapping.
            NSMutableString *key;
            if ([nameString isEqualToString:@"desc"]) {
              key = [NSMutableString stringWithString:@"description"];
            } else {
              key = [NSMutableString stringWithUTF8String:name];
            }
          
            id obj = dictionary[key];
            if (obj == nil) {
                continue;
            }

            const char *type = property_getAttributes(property);
            if ([obj isKindOfClass:[NSString class]]) {
                // if the property type is NSDate, convert the string to a date object
                if (strncmp(type, "T@\"NSDate\",", 11) == 0) {
                    obj = [SLObject dateFromEncodedProperty:obj];
                }
            } else if ([obj isKindOfClass:[NSDictionary class]]) {
                // if the property type is NSMutableData, convert the json object to a data object
                if (strncmp(type, "T@\"NSMutableData\",", 18) == 0 ||
                    strncmp(type, "T@\"NSData\",", 11) == 0) {
                    obj = [SLObject dataFromEncodedProperty:obj];
                }
                // if the property type is CLLocation, convert the json object to a location object
                else if (strncmp(type, "T@\"CLLocation\",", 15) == 0) {
                    obj = [SLObject locationFromEncodedProperty:obj];
                } else {
                  // Attempt to create child model objects if included in the json
                  NSString * typeString = [NSString stringWithUTF8String:type];
                  NSArray * attributes = [typeString componentsSeparatedByString:@","];
                  NSString * typeAttribute = [attributes objectAtIndex:0];
                  if (typeAttribute != nil && [typeAttribute hasPrefix:@"T@"] && [typeAttribute length] > 7) {
                    NSString * typeClassName = [typeAttribute substringWithRange:NSMakeRange(3, [typeAttribute length]-4)];  //turns @"NSDate" into NSDate
                    Class typeClass = NSClassFromString(typeClassName);
                    if (typeClass != nil && [typeClass isSubclassOfClass:[LBModel class]]) {
                      NSString * repoClassName = [NSStringFromClass(typeClass) stringByAppendingString:@"Repository"];
                      Class repoClass = NSClassFromString(repoClassName);
                      if (repoClass != nil && [repoClass isSubclassOfClass:[LBModelRepository class]]) {
                        if ([self.adapter isKindOfClass:[LBRESTAdapter class]]) {
                          LBRESTAdapter * restAdaptor = (LBRESTAdapter *) self.adapter;
                          LBModelRepository * repWithAdaptor = [restAdaptor repositoryWithClass:repoClass];
                          LBModel * internalModel = [repWithAdaptor modelWithDictionary:obj];
                          obj = internalModel;
                        } else {
                          LBModelRepository * rClass = (LBModelRepository *) [[repoClass alloc] init];
                          LBModel * internalModel = [rClass modelWithDictionary:obj];
                          obj = internalModel;
                        }
                      }
                    }
                  }
                }
            } else if ([obj isKindOfClass:[NSNull class]]) { // Handle the case where NULL is explicitly set for an NSObject to make it nil
              obj = nil;
            }
          
            @try {
                if ([key isEqualToString:@"description"]) {
                  [model setValue:obj forKey:@"desc"];
                } else {
                  [model setValue:obj forKey:key];
                }
            }
            @catch (NSException *e) {
              // ignore and log any failure
              NSLog(@"Could not set value on model for key:%@ error:%@", key, e);
            }
        }
        free(props);
    }

    return model;
}

@end
