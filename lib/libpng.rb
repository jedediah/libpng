require 'ffi'
require 'stringio'

module PNG
  module Native
    extend FFI::Library
    ffi_lib 'libpng.so'

    typedef "uint#{FFI::Platform::ADDRESS_SIZE}".intern, :size_t
    typedef :pointer, :structp
    typedef :pointer, :structpp
    typedef :pointer, :infop
    typedef :pointer, :infopp
    typedef :pointer, :voidp
    typedef :pointer, :bytep
    typedef :pointer, :bytepp
    typedef :pointer, :uint32p
    typedef :pointer, :intp
    typedef :int, :transforms

    callback :rw_ptr, [:structp, :bytep, :size_t], :void
    callback :flush_ptr, [:structp], :void
    callback :error_ptr, [:structp, :string], :void

    attach_function :sig_cmp, :png_sig_cmp, [:bytep,:size_t,:size_t], :int
    attach_function :create_read_struct, :png_create_read_struct, [:string, :voidp, :error_ptr, :error_ptr], :structp
    attach_function :destroy_read_struct, :png_destroy_read_struct, [:structpp, :infopp, :infopp], :void
    attach_function :create_info_struct, :png_create_info_struct, [:structp], :infop
    attach_function :destroy_info_struct, :png_destroy_info_struct, [:structp, :infopp], :void

    attach_function :set_read_fn, :png_set_read_fn, [:structp, :voidp, :rw_ptr], :void    # read_struct, io_ptr, read_data_fn
    
    attach_function :read_png, :png_read_png, [:structp, :infop, :transforms, :voidp], :void
    attach_function :get_IHDR, :png_get_IHDR,
                    [:structp, :infop,
                     :uint32p, :uint32p,   # width, height
                     :intp,                # bit depth
                     :intp,                # color type
                     :intp,                # interlace method
                     :intp,                # compression method
                     :intp],               # filter method
                    :uint32

    attach_function :get_image_width, :png_get_image_width, [:structp, :infop], :uint32
    attach_function :get_image_height, :png_get_image_height, [:structp, :infop], :uint32
    attach_function :get_bit_depth, :png_get_bit_depth, [:structp, :infop], :int
    attach_function :get_color_type, :png_get_color_type, [:structp, :infop], :int
    attach_function :get_rows, :png_get_rows, [:structp, :infop], :bytepp
    attach_function :get_rowbytes, :png_get_rowbytes, [:structp, :infop], :uint32
  end

  module ColorMask
    PALETTE = 1
    COLOR = 2
    ALPHA = 4
  end

  module ColorType
    GRAY = 0
    GRAY_ALPHA = ColorMask::ALPHA
    PALETTE = ColorMask::COLOR | ColorMask::PALETTE
    RGB = ColorMask::COLOR
    RGB_ALPHA = ColorMask::COLOR | ColorMask::ALPHA
  end

  ColorTypeNames = { 0 => :GRAY,
                     1 => :PALETTE,
                     2 => :RGB,
                     4 => :GRAY_ALPHA,
                     6 => :RGB_ALPHA }
    
  module Transform
    IDENTITY     = 0x0000
    STRIP_16     = 0x0001
    STRIP_ALPHA  = 0x0002
    PACKING      = 0x0004
    PACKSWAP     = 0x0008
    EXPAND       = 0x0010
    INVERT_MONO  = 0x0020
    SHIFT        = 0x0040
    BGR          = 0x0080
    SWAP_ALPHA   = 0x0100
    SWAP_ENDIAN  = 0x0200
    INVERT_ALPHA = 0x0400
    STRIP_FILLER = 0x0800
  end
  
  Pixel = Struct.new :r, :g, :b, :a

  class Error < RuntimeError; end
  
  class Image
    # maps read_struct pointer addresses to Image instances
    @instances = {}
    @on_warning = proc{|message, image| STDERR.puts "PNG #{image.inspect} warning: #{message}" }

    class << self
      def png? data
        data = data.to_str
        raise "PNG data must have BINARY encoding" unless data.encoding == Encoding::BINARY
        Native.sig_cmp(FFI::MemoryPointer.from_string(data),0,8) == 0
      end

      def register_instance structp, image
        @instances[structp.address] = image
      end

      def get_instance structp
        @instances[structp.address]
      end

      def forget_instance structp
        @instances.delete structp.address
      end

      def on_warning &block
        old = @on_warning
        @on_warning = block
        old
      end
    end
    
    ErrorCallback = proc do |structp, message|
      raise Error.new message
    end

    WarningCallback = proc do |structp, message|
      @on_warning[message,get_instance(structp)]
    end

    ReadCallback = proc do |structp, ptr, length|
      get_instance(structp).read_callback ptr, length
    end

    def read_callback ptr, length
      ptr.write_string_length @input_stream.read(length), length
    end

    def initialize data, transform=Transform::IDENTITY
      if data.respond_to? :to_io
        @input_stream = data.to_io
      else
        @input_stream = StringIO.new data
      end

      sig = @input_stream.read 8
      @input_stream.seek -8, IO::SEEK_CUR
      raise Error.new "Not a PNG" unless Image.png? data

      @structp = Native.create_read_struct "1.2.27",nil,ErrorCallback,WarningCallback
      raise Error.new "png_create_read_struct failed" unless @structp
      self.class.register_instance @structp, self

      @structpp = FFI::MemoryPointer.new :pointer
      @structpp.write_pointer @structp

      @infop = Native.create_info_struct @structp
      unless @infop
        @structp = nil
        Native.destroy_read_struct @structpp, nil, nil
        raise "png_create_info_struct failed"
      end

      @infopp = FFI::MemoryPointer.new :pointer
      @infopp.write_pointer @infop

      Native.set_read_fn @structp, nil, ReadCallback      
      Native.read_png @structp, @infop, transform, nil
      @packed_rows = Native.get_rows(@structp, @infop).read_array_of_pointer height
      @rows = Array.new width
    end

    def width
      Native.get_image_width @structp, @infop
    end

    def height
      Native.get_image_height @structp, @infop
    end

    def bit_depth
      Native.get_bit_depth @structp, @infop
    end

    def color_type
      Native.get_color_type @structp, @infop
    end

    def bytes_per_row
      Native.get_rowbytes @structp, @infop
    end

    def bits_per_pixel
      bit_depth * case color_type
                  when ColorType::GRAY, ColorType::PALETTE; 1
                  when ColorType::GRAY_ALPHA; 2
                  when ColorType::RGB; 3
                  when ColorType::RGB_ALPHA; 4
                  end
    end

    def unpack_row row
      case color_type
      when ColorType::GRAY, ColorType::PALETTE
        case bit_depth
        when 1
          row.unpack("B#{width}").chars.map{|x| x = x.to_f; Pixel.new x,x,x,1.0 }
        when 2
          row.unpack("B#{width*2}").scan(/../).map{|x| x = x.to_i(2).to_f/3; Pixel.new x,x,x,1.0 }
        when 4
          row.unpack("H#{width}").chars.map{|x| x = x.to_i(16).to_f/15; Pixel.new x,x,x,1.0 }
        when 8
          row.bytes.map{|x| x = x.to_f/0xff; Pixel.new x,x,x,1.0 }
        when 16
          row.unpack("n#{width}").map{|x| x = x.to_f/0xffff; Pixel.new x,x,x,1.0 }
        end
      when ColorType::GRAY_ALPHA
        case bit_depth
        when 8
          row.bytes.each_slice(2) {|k,a| k = k.to_f/0xff; Pixel.new k,k,k,a.to_f/0xff }
        when 16
          row.unpack("n#{width*2}").each_slice(2) {|k,a| k = k.to_f/0xffff; Pixel.new k,k,k,a.to_f/0xffff }
        end
      when ColorType::RGB
        arr = []
        case bit_depth
        when 8
          row.scan(/.../) {|s| r,g,b = s.unpack('CCC'); arr << Pixel.new(r.to_f/0xff, g.to_f/0xff, b.to_f/0xff) }
        when 16
          row.scan(/....../) {|s| r,g,b = s.unpack('nnn'); arr << Pixel.new(r.to_f/0xffff, g.to_f/0xffff, b.to_f/0xffff) }
        end
        arr
      when ColorType::RGB_ALPHA
        arr = []
        case bit_depth
        when 8
          row.scan(/..../) {|s| r,g,b,a = s.unpack('CCCC'); arr << Pixel.new(r.to_f/0xff, g.to_f/0xff, b.to_f/0xff, a.to_f/0xff) }
        when 16
          row.scan(/......../) {|s| r,g,b,a = s.unpack('nnnn'); arr << Pixel.new(r.to_f/0xffff, g.to_f/0xffff, b.to_f/0xffff, a.to_f/0xffff) }
        end
        arr
      end
    end
    
    def [] x=nil, y
      @rows[y] ||= unpack_row @packed_rows[y].read_string_length(bytes_per_row)
      if x
        @rows[y][x]
      else
        @rows[y]
      end
    end

    def each_row
      bpr = bytes_per_row
      height.times do |i|
        yield @rows[i] ||= unpack_row(@packed_rows[i].read_string_length(bpr))
      end
    end

    def rows
      enum_for :each_row
    end

  end # Image
end # PNG
