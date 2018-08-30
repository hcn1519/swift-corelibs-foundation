// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//

private class NSCacheEntry<KeyType : AnyObject, ObjectType : AnyObject> {
    var key: KeyType
    var value: ObjectType
    var cost: Int
    var prevByCost: NSCacheEntry?
    var nextByCost: NSCacheEntry?
    init(key: KeyType, value: ObjectType, cost: Int) {
        self.key = key
        self.value = value
        self.cost = cost
    }
}

fileprivate class NSCacheKey: NSObject {
    
    var value: AnyObject
    
    init(_ value: AnyObject) {
        self.value = value
        super.init()
    }
    
    override var hashValue: Int {
        switch self.value {
        case let nsObject as NSObject:
            return nsObject.hashValue
        case let hashable as AnyHashable:
            return hashable.hashValue
        default: return 0
        }
    }
    
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = (object as? NSCacheKey) else { return false }
        
        if self.value === other.value {
            return true
        } else {
            guard let left = self.value as? NSObject,
                let right = other.value as? NSObject else { return false }
            
            return left.isEqual(right)
        }
    }
}

open class NSCache<KeyType : AnyObject, ObjectType : AnyObject> : NSObject {
    
    private var _entries = Dictionary<NSCacheKey, NSCacheEntry<KeyType, ObjectType>>()
    private let _lock = NSLock()
    private var _totalCost = 0
    private var _head: NSCacheEntry<KeyType, ObjectType>?
    
    open var name: String = ""
    open var totalCostLimit: Int = 0 // limits are imprecise/not strict
    open var countLimit: Int = 0 // limits are imprecise/not strict
    open var evictsObjectsWithDiscardedContent: Bool = false

    public override init() {}
    
    open weak var delegate: NSCacheDelegate?
    
    open func object(forKey key: KeyType) -> ObjectType? {
        var object: ObjectType?
        
        let key = NSCacheKey(key)
        
        _lock.lock()
        if let entry = _entries[key] {
            object = entry.value
        }
        _lock.unlock()
        
        return object
    }
    
    open func setObject(_ obj: ObjectType, forKey key: KeyType) {
        setObject(obj, forKey: key, cost: 0)
    }
    
    private func remove(_ entry: NSCacheEntry<KeyType, ObjectType>) {
        let oldPrev = entry.prevByCost
        let oldNext = entry.nextByCost

        //
        // oldPrev
        // ㅁ -> ㅁ -> ㅁ
        // ㅁ <- ㅁ <- ㅁ
        //            oldNext

        oldPrev?.nextByCost = oldNext
        oldNext?.prevByCost = oldPrev

        // oldPrev
        // ㅁ -------> ㅁ
        // ㅁ <------- ㅁ
        //             oldNext
        // remove NSCacheEntry(Node)

        if entry === _head {
            _head = oldNext
        }
    }
   
    private func insert(_ entry: NSCacheEntry<KeyType, ObjectType>) {
        guard var currentElement = _head else {
            // The cache is empty
            entry.prevByCost = nil
            entry.nextByCost = nil
            
            _head = entry
            return
        }
        
        guard entry.cost > currentElement.cost else {
            // Insert entry at the head
            entry.prevByCost = nil
            entry.nextByCost = currentElement
            currentElement.prevByCost = entry
            
            _head = entry
            return
        }

        // order by cost
        // ex) 1 -> 2 -> 10, insert cost 5
        // Loop 1.
        // currentElement = 1
        // nextByCost.cost = 2
        // Loop 2.
        // currentElement = 2
        // nextByCost.cost = 10
        while let nextByCost = currentElement.nextByCost, nextByCost.cost < entry.cost {
            currentElement = nextByCost
        }
        
        // Insert entry between currentElement and nextElement
        // result - 1 -> 2 -> 5 -> 10(cost)
        let nextElement = currentElement.nextByCost
        
        currentElement.nextByCost = entry
        entry.prevByCost = currentElement
        
        entry.nextByCost = nextElement
        nextElement?.prevByCost = entry
    }
    
    open func setObject(_ obj: ObjectType, forKey key: KeyType, cost g: Int) {
        let g = max(g, 0)
        let keyRef = NSCacheKey(key)
        
        _lock.lock()
        
        let costDiff: Int

        // 현재  _entries에 값이 존재
        if let entry = _entries[keyRef] {
            costDiff = g - entry.cost
            entry.cost = g
            
            entry.value = obj

            // cost가 설정되어 있는 경우
            if costDiff != 0 {
                // 기존 값 제거 후, 새로운 값 삽입
                remove(entry)
                insert(entry)
            }
        } else {
            // 현재  _entries에 값이 없음
            let entry = NSCacheEntry(key: key, value: obj, cost: g)
            _entries[keyRef] = entry

            // 새로운 값 삽입
            insert(entry)
            
            costDiff = g
        }
        
        _totalCost += costDiff

        /// CostLimit에 기반하여 데이터 제거(Purging)
        // purgeAmount = 줄여야 하는 cost의 총량
        var purgeAmount = (totalCostLimit > 0) ? (_totalCost - totalCostLimit) : 0
        while purgeAmount > 0 {
            if let entry = _head {
                delegate?.cache(unsafeDowncast(self, to:NSCache<AnyObject, AnyObject>.self), willEvictObject: entry.value)

                // 작은 cost의 데이터들부터 제거해나감
                _totalCost -= entry.cost
                purgeAmount -= entry.cost
                
                remove(entry) // _head will be changed to next entry in remove(_:)
                _entries[NSCacheKey(entry.key)] = nil
            } else {
                break
            }
        }

        /// CountLimit에 기반하여 데이터 제거(Purging)
        var purgeCount = (countLimit > 0) ? (_entries.count - countLimit) : 0
        while purgeCount > 0 {
            if let entry = _head {
                delegate?.cache(unsafeDowncast(self, to:NSCache<AnyObject, AnyObject>.self), willEvictObject: entry.value)
                
                _totalCost -= entry.cost
                purgeCount -= 1
                
                remove(entry) // _head will be changed to next entry in remove(_:)
                _entries[NSCacheKey(entry.key)] = nil
            } else {
                break
            }
        }
        
        _lock.unlock()
    }
    
    open func removeObject(forKey key: KeyType) {
        let keyRef = NSCacheKey(key)
        
        _lock.lock()
        if let entry = _entries.removeValue(forKey: keyRef) {
            _totalCost -= entry.cost
            remove(entry)
        }
        _lock.unlock()
    }
    
    open func removeAllObjects() {
        _lock.lock()
        _entries.removeAll()
        
        while let currentElement = _head {
            let nextElement = currentElement.nextByCost
            
            currentElement.prevByCost = nil
            currentElement.nextByCost = nil
            
            _head = nextElement
        }
        
        _totalCost = 0
        _lock.unlock()
    }    
}

public protocol NSCacheDelegate : NSObjectProtocol {
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any)
}

extension NSCacheDelegate {
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        // Default implementation does nothing
    }
}
