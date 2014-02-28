using Protobuf

import Protobuf.meta

# enable logging only during debugging
using Logging
const logger = Logging.configure(filename="protogen.log", level=DEBUG)
logmsg(s) = debug(s)
#logmsg(s) = nothing


include("descriptor_protos.jl")
include("plugin_protos.jl")

type Scope
    name::String
    syms::Array{String,1}
    parent::Scope

    function Scope(name::String) 
        s = new()
        s.name = name
        s.syms = String[]
        s
    end
    function Scope(name::String, parent::Scope)
        s = new()
        s.name = name
        s.syms = String[]
        s.parent = parent
        s
    end
end

function qualify(name::String, scope::Scope) 
    if name in scope.syms
        return pfx(name, scope.name) 
    elseif isdefined(scope, parent) 
        return qualify(name, scope.parent) 
    else
        error("unresolved name $name at scope $(scope.name)")
    end
end

function readreq(srcio::IO)
    req = CodeGeneratorRequest()
    readproto(srcio, req)
    req
end

pfx(name::String, pfx::String) = isempty(pfx) ? name : (pfx * "_" * name)

function generate(io::IO, errio::IO, enumtype::EnumDescriptorProto, scope::Scope)
    enumname = pfx(enumtype.name, scope.name)
    push!(scope.syms, enumtype.name)

    logmsg("begin enum $(enumname)")
    println(io, "type __enum_$(enumname)")
    values = Int32[]
    for value::EnumValueDescriptorProto in enumtype.value
        println(io, "    $(value.name)::Int32")
        push!(values, value.number)
    end
    println(io, "    __enum_$(enumname)() = new($(join(values,',')))")
    println(io, "end #type __enum_$(enumname)")
    println(io, "const $(enumname) = __enum_$(enumname)()")
    println(io, "")
    logmsg("end enum $(enumname)")
end

function generate(io::IO, errio::IO, dtype::DescriptorProto, scope::Scope)
    dtypename = pfx(dtype.name, scope.name)
    logmsg("begin type $(dtypename)")

    scope = Scope(dtypename, scope)
    # generate enums
    if filled(dtype, :enum_type)
        for enum_type in dtype.enum_type
            generate(io, errio, enum_type, scope)
            (errio.size > 0) && return 
        end
    end

    # generate nested types
    if filled(dtype, :nested_type)
        for nested_type::DescriptorProto in dtype.nested_type
            generate(io, errio, nested_type, scope)
            (errio.size > 0) && return 
        end
    end

    # generate this type
    println(io, "type $(dtypename)")
    reqflds = String[]
    fldnums = Int[]
    defvals = String[]
    for field::FieldDescriptorProto in dtype.field
        fldname = field.name
        if field.typ == TYPE_GROUP
            println(errio, "Groups are not supported")
            return
        end

        if field.typ == TYPE_MESSAGE
            typ_name = field.typ_name
            if beginswith(typ_name, '.')
                typ_name = replace(typ_name[2:end], '.', '_')
            else
                typ_name = qualify(typ_name, scope)
            end
        else
            typ_name = "$(JTYPES[field.typ])"
        end

        push!(fldnums, field.number)
        (LABEL_REQUIRED == field.label) && push!(reqflds, ":"*fldname)

        if filled(field, :default_value) && !isempty(field.default_value)
            if field.typ == TYPE_STRING
                push!(defvals, ":$fldname => \"$(escape_string(field.default_value))\"")
            elseif field.typ == TYPE_MESSAGE
                println(errio, "Default values for message types are not supported. Field: $(dtypename).$(fldname) has default value [$(field.default_value)]")
                return
            elseif field.typ == TYPE_BYTES
                println(errio, "Default values for byte array types are not supported. Field: $(dtypename).$(fldname) has default value [$(field.default_value)]")
                return
            else
                push!(defvals, ":$fldname => $(field.default_value)")
            end
        end

        (LABEL_REPEATED == field.label) && (typ_name = "Array{$typ_name,1}")
        println(io, "    $(field.name)::$typ_name")
    end
    println(io, "    $(dtypename)() = new()")
    println(io, "end #type $(dtypename)")

    # generate the meta for this type if required
    if !isempty(reqflds) || !isempty(defvals) || (fldnums != [1:length(fldnums)])
        logmsg("generating meta for type $(dtypename)")
        print(io, "meta(t::Type{$dtypename}) = meta(t, true, Symbol[")
        !isempty(reqflds) && print(io, join(reqflds, ','))
        print(io, "], Int[")
        (fldnums != [1:length(fldnums)]) && print(io, join(fldnums, ','))
        print(io, "], Dict{Symbol,Any}(")
        if !isempty(defvals)
            print(io, "{" * join(defvals, ',') * "}")
        end
        println(io, "))")
    end

    println(io, "")
    logmsg("end type $(dtypename)")
end

function generate(io::IO, errio::IO, protofile::FileDescriptorProto)
    logmsg("generate begin for $(protofile.name)")

    scope = Scope("")

    # generate top level enums
    if filled(protofile, :enum_type)
        for enum_type in protofile.enum_type
            generate(io, errio, enum_type, scope)
            (errio.size > 0) && return 
        end
    end

    # generate message types
    if filled(protofile, :message_type)
        for message_type in protofile.message_type
            generate(io, errio, message_type, scope)
            (errio.size > 0) && return 
        end
    end

    logmsg("generate end for $(protofile.name)")
end

function append_response(resp::CodeGeneratorResponse, protofile::FileDescriptorProto, io::IOBuffer)
    jfile = CodeGenFile()

    jfile.name = join([splitext(protofile.name)[1],"jl"], '.')
    jfile.content = takebuf_string(io)

    !isdefined(resp, :file) && (resp.file = CodeGenFile[])
    push!(resp.file, jfile)
    resp
end

function err_response(errio::IOBuffer)
    resp = CodeGeneratorResponse()
    resp.error = takebuf_string(errio)
    resp
end

function generate(srcio::IO)
    errio = IOBuffer()
    resp = CodeGeneratorResponse()
    logmsg("generate begin")
    while !eof(srcio)
        req = readreq(srcio)

        if !filled(req, :file_to_generate)
            logmsg("no files to generate!!")
            continue
        end

        logmsg("generate request for $(length(req.file_to_generate)) proto files")
        logmsg("$(req.file_to_generate)")

        filled(req, :parameter) && logmsg("parameter $(req.parameter)")

        for protofile in req.proto_file
            io = IOBuffer()
            println(io, "using Protobuf")
            println(io, "import Protobuf.meta")
            println(io, "")
            generate(io, errio, protofile)
            (errio.size > 0) && return err_response(errio)
            append_response(resp, protofile, io)
        end
    end
    logmsg("generate end")
    resp
end


##
# the main read - write method
try
    writeproto(STDOUT, generate(STDIN))
catch ex
    println(STDERR, "Exception while generating Julia code")
    println(STDERR, ex)
    exit(-1)
end

