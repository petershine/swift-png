import Glibc

protocol DataSource
{
    mutating 
    func read(bytes limit:Int) -> [UInt8]
}

enum PNG
{
    struct FileInterface:DataSource 
    {
        typealias FilePointer = UnsafeMutablePointer<FILE>
        
        private 
        let descriptor:FilePointer
        
        static 
        func open(path:String) -> FileInterface? 
        {
            guard let descriptor:FilePointer = fopen(path, "rb")
            else
            {
                return nil
            }
            
            return .init(descriptor: descriptor)
        }
        
        func close()
        {
            fclose(self.descriptor)
        }
        
        func read(bytes limit:Int) -> [UInt8]
        {
            return .init(_unsafeUninitializedCapacity: limit) 
            {
                (buffer:inout UnsafeMutableBufferPointer<UInt8>, count:inout Int) in 
                
                count = fread(buffer.baseAddress, 1, limit, self.descriptor)
            }
        }
    }
    
    public 
    struct Properties
    {
        public 
        enum Format:UInt16 
        {
            // bitfield contains depth in upper byte, then code in lower byte
            case grayscale1     = 0x01_00,
                 grayscale2     = 0x02_00,
                 grayscale4     = 0x04_00,
                 grayscale8     = 0x08_00,
                 grayscale16    = 0x10_00,
                 rgb8           = 0x08_02,
                 rgb16          = 0x10_02,
                 indexed1       = 0x01_03,
                 indexed2       = 0x02_03,
                 indexed4       = 0x04_03,
                 indexed8       = 0x08_03,
                 grayscale_a8   = 0x08_04,
                 grayscale_a16  = 0x10_04,
                 rgba8          = 0x08_06,
                 rgba16         = 0x10_06
            
            var isIndexed:Bool 
            {
                return self.rawValue & 1 != 0
            }
            var hasColor:Bool 
            {
                return self.rawValue & 2 != 0
            }
            var hasAlpha:Bool 
            {
                return self.rawValue & 4 != 0
            }
            
            
            public 
            var depth:Int
            {
                return .init(self.rawValue >> 8)
            }
            
            public 
            var channels:Int
            {
                switch self
                {
                case .grayscale1, .grayscale2, .grayscale4, .grayscale8, .grayscale16,
                    .indexed1, .indexed2, .indexed4, .indexed8:
                    return 1
                case .grayscale_a8, .grayscale_a16:
                    return 2
                case .rgb8, .rgb16:
                    return 3
                case .rgba8, .rgba16:
                    return 4
                }
            }
            
            // difference between this and channels is indexed pngs have 3 components 
            public 
            var components:Int 
            {
                //        base +     2 × colored     +    alpha
                return .init(1 + (self.rawValue & 2) + (self.rawValue & 4) >> 2)
            }
            
            func shape(from size:Math<Int>.V2) -> Shape 
            {
                let scanlineBitCount:Int = size.x * self.channels * self.depth
                                                // ceil(scanlineBitCount / 8)
                let pitch:Int = scanlineBitCount >> 3 + (scanlineBitCount & 7 == 0 ? 0 : 1)
                return .init(pitch: pitch, size: size)
            }
        }
        
        struct Shape 
        {
            let pitch:Int, 
                size:Math<Int>.V2
            
            var byteCount:Int 
            {
                return self.pitch * self.size.y
            }
        }
        
        enum Interlacing 
        {
            struct SubImage 
            {
                let shape:Shape, 
                    strider:Math<StrideTo<Int>>.V2
            }
            
            case none, 
                 adam7([SubImage])
            
            static 
            func computeAdam7Ranges(_ subImages:[SubImage]) -> [Range<Int>]
            {
                var accumulator:Int = 0
                return subImages.map
                {
                    let upper:Int = accumulator + $0.shape.byteCount 
                    defer 
                    {
                        accumulator = upper 
                    }
                    
                    return accumulator ..< upper
                }
            }
        }
        
        struct Pitches:Sequence, IteratorProtocol 
        {
            private 
            let footprints:[(pitch:Int, height:Int)]
            
            private 
            var f:Int         = 0, 
                scanlines:Int = 0
            
            mutating 
            func next() -> Int? 
            {
                while self.scanlines == 0  
                {
                    guard self.f < self.footprints.count
                    else 
                    {
                        return nil  
                    }
                    
                    self.scanlines = self.footprints[self.f].pitch * self.footprints[self.f].height
                    self.f += 1
                }
                
                self.scanlines -= 1 
                return self.footprints[self.f - 1].pitch
            }
        }
        
        // stored properties 
        public 
        let format:Format
        
        public 
        var palette:[RGBA<UInt8>]?,
            chromaKey:RGBA<UInt16>?
        
        let shape:Shape, 
            interlacing:Interlacing
        
        // computed properties 
        public 
        var interlaced:Bool
        {
            if case .adam7 = self.interlacing 
            {
                return true 
            }
            else 
            {
                return false
            }
        }
        
        public 
        init(size:Math<Int>.V2, format:Format, interlaced:Bool)
        {
            self.format = format
            self.shape  = format.shape(from: size)
            
            if interlaced 
            {
                // calculate size of interlaced subimages
                // 0: (w + 7) >> 3 , (h + 7) >> 3
                // 1: (w + 3) >> 3 , (h + 7) >> 3
                // 2: (w + 3) >> 2 , (h + 3) >> 3
                // 3: (w + 1) >> 2 , (h + 3) >> 2
                // 4: (w + 1) >> 1 , (h + 1) >> 2
                // 5: (w) >> 1     , (h + 1) >> 1
                // 6: (w)          , (h) >> 1
                let sizes:[Math<Int>.V2] = 
                [
                    ((size.x + 7) >> 3, (size.y + 7) >> 3),
                    ((size.x + 3) >> 3, (size.y + 7) >> 3),
                    ((size.x + 3) >> 2, (size.y + 3) >> 3),
                    ((size.x + 1) >> 2, (size.y + 3) >> 2),
                    ((size.x + 1) >> 1, (size.y + 1) >> 2),
                    ( size.x      >> 1, (size.y + 1) >> 1),
                    ( size.x      >> 0,  size.y      >> 1)
                ]
                
                let striders:[Math<StrideTo<Int>>.V2] = 
                [
                    (stride(from: 0, to: size.x, by: 8), stride(from: 0, to: size.y, by: 8)),
                    (stride(from: 4, to: size.x, by: 8), stride(from: 0, to: size.y, by: 8)),
                    (stride(from: 0, to: size.x, by: 4), stride(from: 4, to: size.y, by: 8)),
                    (stride(from: 2, to: size.x, by: 4), stride(from: 0, to: size.y, by: 4)),
                    (stride(from: 0, to: size.x, by: 2), stride(from: 2, to: size.y, by: 4)),
                    (stride(from: 1, to: size.x, by: 2), stride(from: 0, to: size.y, by: 2)),
                    (stride(from: 0, to: size.x, by: 1), stride(from: 1, to: size.y, by: 2))
                ]
                
                let subImages:[Interlacing.SubImage] = zip(sizes, striders).map
                {
                    (size:Math<Int>.V2, strider:Math<StrideTo<Int>>.V2) in 
                    
                    return .init(shape: format.shape(from: size), strider: strider)
                }
                
                self.interlacing = .adam7(subImages)
            }
            else 
            {
                self.interlacing = .none
            }
        }
    }
    
    enum Data 
    {
        // PNG data that has been decompressed, but not necessarily deinterlaced 
        struct Uncompressed 
        {
            let properties:Properties, 
                data:[UInt8]
            
            func decompose() -> [Rectangular]?
            {
                guard case .adam7(let subImages) = self.properties.interlacing 
                else 
                {
                    return nil
                }
                
                let ranges:[Range<Int>] = Properties.Interlacing.computeAdam7Ranges(subImages)
                
                assert(self.data.count == ranges[6].upperBound)
                
                return zip(ranges, subImages).map 
                {
                    (range:Range<Int>, subImage:Properties.Interlacing.SubImage) in 
                    
                    let properties:Properties = .init(size: subImage.shape.size, 
                                                    format: self.properties.format, 
                                                interlaced: false)
                    
                    return .init(properties: properties, data: .init(self.data[range]))
                }
            }
            
            func deinterlace() -> Rectangular 
            {
                guard case .adam7(let subImages) = self.properties.interlacing 
                else 
                {
                    // image is not interlaced at all, return it transparently 
                    assert(self.data.count == self.properties.shape.byteCount)
                    return .init(properties: self.properties, data: self.data)
                }
                
                let properties:Properties = .init(size: self.properties.shape.size, 
                                                format: self.properties.format, 
                                            interlaced: false)
                let count:Int = properties.shape.byteCount
                let deinterlaced:[UInt8] = .init(_unsafeUninitializedCapacity: count)
                {
                    (buffer:inout UnsafeMutableBufferPointer<UInt8>, count:inout Int) in
                    
                    let depth:Int = properties.format.depth
                    if depth < 8 
                    {
                        var base:Int = self.data.startIndex 
                        for subImage:Properties.Interlacing.SubImage in subImages 
                        {
                            for (sy, dy):(Int, Int) in subImage.strider.y.enumerated()
                            {                            
                                for (sx, dx):(Int, Int) in subImage.strider.x.enumerated()
                                {
                                    // image only has 1 channel 
                                    let si:Int = (sx * depth) >> 3 + subImage.shape.pitch   * sy, 
                                        di:Int = (dx * depth) >> 3 + properties.shape.pitch * dy
                                    let sb:Int = (sx * depth) & 7, 
                                        db:Int = (dx * depth) & 7
                                    
                                    // isolate relevant bits and store them into the destination
                                    let bits:UInt8 = (self.data[base + si] &<< sb) &>> (8 - depth)
                                    buffer[di]    |= bits &<< (8 - db - depth) 
                                }
                            }
                            
                            base += subImage.shape.byteCount
                        }
                    }
                    else 
                    {
                        let bpp:Int = (properties.format.channels * depth) >> 3
                        
                        var base:Int = self.data.startIndex 
                        for subImage:Properties.Interlacing.SubImage in subImages 
                        {
                            for (sy, dy):(Int, Int) in subImage.strider.y.enumerated()
                            {                            
                                for (sx, dx):(Int, Int) in subImage.strider.x.enumerated()
                                {
                                    let si:Int = sx * bpp + subImage.shape.pitch   * sy, 
                                        di:Int = dx * bpp + properties.shape.pitch * dy
                                    
                                    for b:Int in 0 ..< bpp 
                                    {
                                        buffer[di + b] = self.data[base + si + b]
                                    }
                                }
                            }
                            
                            base += subImage.shape.byteCount
                        }
                    }
                }
                
                return .init(properties: properties, data: deinterlaced)
            }
        }
        
        // PNG data that has been deinterlaced, but may still have multiple pixels 
        // packed per byte, or indirect (indexed) pixels
        struct Rectangular 
        {
            let properties:Properties, 
                data:[UInt8]
        }
    }
    
    enum Chunk:String
    {
        case __FIRST__,
             IHDR,
             PLTE,
             IDAT,
             IEND,

             cHRM,
             gAMA,
             iCCP,
             sBIT,
             sRGB,
             bKGD,
             hIST,
             tRNS,
             pHYs,
             sPLT,
             tIME,
             iTXt,
             tEXt,
             zTXt,

             PRIVATE,

             __INTERRUPTOR__
    }
    
    enum ReadError:Error
    {
        case missingHeader, 
             prematureIEND, 
             illegalChunk(Chunk), 
             misplacedChunk(Chunk), 
             duplicateChunk(Chunk), 
             missingPalette
    }

    // performs chunk ordering and presence validation
    struct Conditions 
    {
        private 
        var lastValidChunk:Chunk = .__FIRST__, 
            seen:Set<Chunk>      = [], 
            format:Properties.Format?
        
        mutating 
        func push(_ chunk:Chunk) -> ReadError? 
        {
            if self.lastValidChunk == .__FIRST__
            {
                guard chunk == .IHDR 
                else 
                {
                    return .missingHeader 
                }
                
                self.lastValidChunk = .IHDR 
                self.seen.insert(.IHDR)
                return nil 
            }
            
            guard self.lastValidChunk != .IEND || chunk == .IEND && !self.seen.contains(.IDAT)
            else 
            {
                return .prematureIEND
            }
            
            guard let format:Properties.Format = self.format
            else 
            {
                return .missingHeader
            }
            
            
            if      chunk ==                                                                  .tRNS
            {
                guard !format.hasAlpha // tRNS forbidden in alpha’d formats
                else
                {
                    return .illegalChunk(chunk)
                }
            }
            else if chunk ==   .PLTE
            {
                // PLTE must come before bKGD, hIST, and tRNS
                guard format.hasColor // PLTE requires non-grayscale format
                else
                {
                    return .illegalChunk(chunk)
                }

                if self.seen.contains(.bKGD) || self.seen.contains(.hIST) || self.seen.contains(.tRNS)
                {
                    return .misplacedChunk(chunk)
                }
            }

            // these chunks must occur before PLTE
            switch chunk
            {
                case                         .cHRM, .gAMA, .iCCP, .sBIT, .sRGB:
                    if self.seen.contains(.PLTE)
                    {
                        return .misplacedChunk(chunk)
                    }
                    
                    fallthrough 
                
                // these chunks (and the ones in previous cases) must occur before IDAT
                case           .PLTE,                                           .bKGD, .hIST, .tRNS, .pHYs, .sPLT:
                    if self.seen.contains(.IDAT)
                    {
                        return .misplacedChunk(chunk)
                    }
                    
                    fallthrough 
                
                // these chunks (and the ones in previous cases) cannot duplicate
                case    .IHDR,                                                                                     .tIME:
                    if self.seen.contains(chunk)
                    {
                        return .duplicateChunk(chunk)
                    }
                
                
                // IDAT blocks much be consecutive
                case .IDAT:
                    if  self.lastValidChunk != .IDAT, 
                        self.seen.contains(.IDAT)
                    {
                        return .misplacedChunk(chunk)
                    }

                    if  format.isIndexed, 
                       !self.seen.contains(.PLTE)
                    {
                        return .missingPalette
                    }
                    
                default:
                    break
            }
            
            self.lastValidChunk = chunk
            self.seen.insert(chunk)
            
            return nil
        }
    }
}
