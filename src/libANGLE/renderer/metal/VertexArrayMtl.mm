//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// VertexArrayMtl.mm:
//    Implements the class methods for VertexArrayMtl.
//

#include "libANGLE/renderer/metal/VertexArrayMtl.h"
#include "libANGLE/renderer/metal/BufferMtl.h"
#include "libANGLE/renderer/metal/ContextMtl.h"
#include "libANGLE/renderer/metal/DisplayMtl.h"
#include "libANGLE/renderer/metal/mtl_format_utils.h"

#include "common/debug.h"

namespace rx
{
namespace
{
constexpr size_t kDynamicIndexDataSize = 1024 * 8;

angle::Result StreamVertexData(ContextMtl *contextMtl,
                               mtl::BufferPool *dynamicBuffer,
                               const uint8_t *sourceData,
                               size_t bytesToAllocate,
                               size_t destOffset,
                               size_t vertexCount,
                               size_t stride,
                               VertexCopyFunction vertexLoadFunction,
                               SimpleWeakBufferHolderMtl *bufferHolder,
                               size_t *bufferOffsetOut)
{
    ANGLE_CHECK(contextMtl, vertexLoadFunction, "Unsupported format conversion", GL_INVALID_ENUM);
    uint8_t *dst = nullptr;
    mtl::BufferRef newBuffer;
    ANGLE_TRY(dynamicBuffer->allocate(contextMtl, bytesToAllocate, &dst, &newBuffer,
                                      bufferOffsetOut, nullptr));
    bufferHolder->set(newBuffer);
    dst += destOffset;
    vertexLoadFunction(sourceData, stride, vertexCount, dst);

    ANGLE_TRY(dynamicBuffer->commit(contextMtl));
    return angle::Result::Continue;
}

template <typename SizeT>
const mtl::VertexFormat &GetVertexConversionFormat(ContextMtl *contextMtl,
                                                   angle::FormatID originalFormat,
                                                   SizeT *strideOut)
{
    // Convert to tightly packed format
    const mtl::VertexFormat &packedFormat = contextMtl->getVertexFormat(originalFormat, true);
    *strideOut                            = packedFormat.actualAngleFormat().pixelBytes;
    return packedFormat;
}

size_t GetIndexConvertedBufferSize(gl::DrawElementsType indexType, size_t indexCount)
{
    size_t elementSize = gl::GetDrawElementsTypeSize(indexType);
    if (indexType == gl::DrawElementsType::UnsignedByte)
    {
        // 8-bit indices are not supported by Metal, so they are promoted to
        // 16-bit indices below
        elementSize = sizeof(GLushort);
    }

    const size_t amount = elementSize * indexCount;

    return amount;
}

angle::Result StreamIndexData(ContextMtl *contextMtl,
                              mtl::BufferPool *dynamicBuffer,
                              const uint8_t *sourcePointer,
                              gl::DrawElementsType indexType,
                              size_t indexCount,
                              mtl::BufferRef *bufferOut,
                              size_t *bufferOffsetOut)
{
    dynamicBuffer->releaseInFlightBuffers(contextMtl);

    const size_t amount = GetIndexConvertedBufferSize(indexType, indexCount);
    GLubyte *dst        = nullptr;

    ANGLE_TRY(
        dynamicBuffer->allocate(contextMtl, amount, &dst, bufferOut, bufferOffsetOut, nullptr));

    if (indexType == gl::DrawElementsType::UnsignedByte)
    {
        // Unsigned bytes don't have direct support in Metal so we have to expand the
        // memory to a GLushort.
        const GLubyte *in     = static_cast<const GLubyte *>(sourcePointer);
        GLushort *expandedDst = reinterpret_cast<GLushort *>(dst);

        // NOTE(hqle): May need to handle primitive restart index in future when ES 3.0
        // is supported.
        // Fast path for common case.
        for (size_t index = 0; index < indexCount; index++)
        {
            expandedDst[index] = static_cast<GLushort>(in[index]);
        }
    }
    else
    {
        memcpy(dst, sourcePointer, amount);
    }
    ANGLE_TRY(dynamicBuffer->commit(contextMtl));

    return angle::Result::Continue;
}

size_t GetVertexCount(BufferMtl *srcBuffer,
                      const gl::VertexBinding &binding,
                      uint32_t srcFormatSize)
{
    // Bytes usable for vertex data.
    GLint64 bytes = srcBuffer->size() - binding.getOffset();
    if (bytes < srcFormatSize)
        return 0;

    // Count the last vertex.  It may occupy less than a full stride.
    size_t numVertices = 1;
    bytes -= srcFormatSize;

    // Count how many strides fit remaining space.
    if (bytes > 0)
        numVertices += static_cast<size_t>(bytes) / binding.getStride();

    return numVertices;
}

inline size_t GetIndexCount(BufferMtl *srcBuffer, size_t offset, gl::DrawElementsType indexType)
{
    size_t elementSize = gl::GetDrawElementsTypeSize(indexType);
    return (srcBuffer->size() - offset) / elementSize;
}

inline void SetDefaultVertexBufferLayout(mtl::VertexBufferLayoutDesc *layout)
{
    layout->stepFunction = mtl::kVertexStepFunctionInvalid;
    layout->stepRate     = 0;
    layout->stride       = 0;
}

}  // namespace

// VertexArrayMtl implementation
VertexArrayMtl::VertexArrayMtl(const gl::VertexArrayState &state, ContextMtl *context)
    : VertexArrayImpl(state),
      // Due to Metal's strict requirement for offset and stride, we need to always allocate new
      // buffer for every conversion.
      mDynamicVertexData(true)
{
    reset(context);

    mDynamicVertexData.initialize(context, 0, mtl::kVertexAttribBufferStrideAlignment,
                                  /** maxBuffers */ 10 * mtl::kMaxVertexAttribs);

    mDynamicIndexData.initialize(context, kDynamicIndexDataSize, mtl::kIndexBufferOffsetAlignment);
}
VertexArrayMtl::~VertexArrayMtl() {}

void VertexArrayMtl::destroy(const gl::Context *context)
{
    ContextMtl *contextMtl = mtl::GetImpl(context);

    reset(contextMtl);

    mDynamicVertexData.destroy(contextMtl);
    mDynamicIndexData.destroy(contextMtl);
}

void VertexArrayMtl::reset(ContextMtl *context)
{
    for (BufferHolderMtl *&buffer : mCurrentArrayBuffers)
    {
        buffer = nullptr;
    }
    for (size_t &offset : mCurrentArrayBufferOffsets)
    {
        offset = 0;
    }
    for (GLuint &stride : mCurrentArrayBufferStrides)
    {
        stride = 0;
    }
    for (const mtl::VertexFormat *&format : mCurrentArrayBufferFormats)
    {
        format = &context->getVertexFormat(angle::FormatID::R32G32B32A32_FLOAT, false);
    }

    for (size_t &inlineDataSize : mCurrentArrayInlineDataSizes)
    {
        inlineDataSize = 0;
    }

    for (angle::MemoryBuffer &convertedClientArray : mConvertedClientSmallArrays)
    {
        convertedClientArray.resize(0);
    }

    for (const uint8_t *&clientPointer : mCurrentArrayInlineDataPointers)
    {
        clientPointer = nullptr;
    }

    mVertexArrayDirty = true;
}

angle::Result VertexArrayMtl::syncState(const gl::Context *context,
                                        const gl::VertexArray::DirtyBits &dirtyBits,
                                        gl::VertexArray::DirtyAttribBitsArray *attribBits,
                                        gl::VertexArray::DirtyBindingBitsArray *bindingBits)
{
    const std::vector<gl::VertexAttribute> &attribs = mState.getVertexAttributes();
    const std::vector<gl::VertexBinding> &bindings  = mState.getVertexBindings();

    for (size_t dirtyBit : dirtyBits)
    {
        switch (dirtyBit)
        {
            case gl::VertexArray::DIRTY_BIT_ELEMENT_ARRAY_BUFFER:
            case gl::VertexArray::DIRTY_BIT_ELEMENT_ARRAY_BUFFER_DATA:
            {
                break;
            }

#define ANGLE_VERTEX_DIRTY_ATTRIB_FUNC(INDEX)                                                     \
    case gl::VertexArray::DIRTY_BIT_ATTRIB_0 + INDEX:                                             \
        ANGLE_TRY(syncDirtyAttrib(context, attribs[INDEX], bindings[attribs[INDEX].bindingIndex], \
                                  INDEX));                                                        \
        mVertexArrayDirty = true;                                                                 \
        (*attribBits)[INDEX].reset();                                                             \
        break;

                ANGLE_VERTEX_INDEX_CASES(ANGLE_VERTEX_DIRTY_ATTRIB_FUNC)

#define ANGLE_VERTEX_DIRTY_BINDING_FUNC(INDEX)                                                    \
    case gl::VertexArray::DIRTY_BIT_BINDING_0 + INDEX:                                            \
        ANGLE_TRY(syncDirtyAttrib(context, attribs[INDEX], bindings[attribs[INDEX].bindingIndex], \
                                  INDEX));                                                        \
        mVertexArrayDirty = true;                                                                 \
        (*bindingBits)[INDEX].reset();                                                            \
        break;

                ANGLE_VERTEX_INDEX_CASES(ANGLE_VERTEX_DIRTY_BINDING_FUNC)

#define ANGLE_VERTEX_DIRTY_BUFFER_DATA_FUNC(INDEX)                                                \
    case gl::VertexArray::DIRTY_BIT_BUFFER_DATA_0 + INDEX:                                        \
        ANGLE_TRY(syncDirtyAttrib(context, attribs[INDEX], bindings[attribs[INDEX].bindingIndex], \
                                  INDEX));                                                        \
        mVertexArrayDirty = true;                                                                 \
        break;

                ANGLE_VERTEX_INDEX_CASES(ANGLE_VERTEX_DIRTY_BUFFER_DATA_FUNC)

            default:
                UNREACHABLE();
                break;
        }
    }

    return angle::Result::Continue;
}

// vertexDescChanged is both input and output, the input value if is true, will force new
// mtl::VertexDesc to be returned via vertexDescOut. This typically happens when active shader
// program is changed.
// Otherwise, it is only returned when the vertex array is dirty.
angle::Result VertexArrayMtl::setupDraw(const gl::Context *glContext,
                                        mtl::RenderCommandEncoder *cmdEncoder,
                                        bool *vertexDescChanged,
                                        mtl::VertexDesc *vertexDescOut)
{
    // NOTE(hqle): consider only updating dirty attributes
    bool dirty = mVertexArrayDirty || *vertexDescChanged;

    if (dirty)
    {
        mVertexArrayDirty = false;

        const gl::ProgramState &programState = glContext->getState().getProgram()->getState();
        const gl::AttributesMask &programActiveAttribsMask =
            programState.getActiveAttribLocationsMask();

        const std::vector<gl::VertexAttribute> &attribs = mState.getVertexAttributes();
        const std::vector<gl::VertexBinding> &bindings  = mState.getVertexBindings();

        mtl::VertexDesc &desc = *vertexDescOut;

        desc.numAttribs       = mtl::kMaxVertexAttribs;
        desc.numBufferLayouts = mtl::kMaxVertexAttribs;

        // Initialize the buffer layouts with constant step rate
        for (uint32_t b = 0; b < mtl::kMaxVertexAttribs; ++b)
        {
            SetDefaultVertexBufferLayout(&desc.layouts[b]);
        }

        for (uint32_t v = 0; v < mtl::kMaxVertexAttribs; ++v)
        {
            if (!programActiveAttribsMask.test(v))
            {
                desc.attributes[v].format      = MTLVertexFormatInvalid;
                desc.attributes[v].bufferIndex = 0;
                desc.attributes[v].offset      = 0;
                continue;
            }

            const auto &attrib               = attribs[v];
            const gl::VertexBinding &binding = bindings[attrib.bindingIndex];

            const angle::Format &angleFormat = mCurrentArrayBufferFormats[v]->actualAngleFormat();
            desc.attributes[v].format        = mCurrentArrayBufferFormats[v]->metalFormat;

            bool attribEnabled = attrib.enabled;
            if (attribEnabled && !mCurrentArrayBuffers[v] && !mCurrentArrayInlineDataPointers[v])
            {
                // Disable it to avoid crash.
                attribEnabled = false;
            }

            if (!attribEnabled)
            {
                desc.attributes[v].bufferIndex = mtl::kDefaultAttribsBindingIndex;
                desc.attributes[v].offset      = v * mtl::kDefaultAttributeSize;
            }
            else
            {
                uint32_t bufferIdx    = mtl::kVboBindingIndexStart + v;
                uint32_t bufferOffset = static_cast<uint32_t>(mCurrentArrayBufferOffsets[v]);

                desc.attributes[v].bufferIndex = bufferIdx;
                desc.attributes[v].offset      = 0;
                ASSERT((bufferOffset % angleFormat.pixelBytes) == 0);

                ASSERT(bufferIdx < mtl::kMaxVertexAttribs);
                if (binding.getDivisor() == 0)
                {
                    desc.layouts[bufferIdx].stepFunction = MTLVertexStepFunctionPerVertex;
                    desc.layouts[bufferIdx].stepRate     = 1;
                }
                else
                {
                    desc.layouts[bufferIdx].stepFunction = MTLVertexStepFunctionPerInstance;
                    desc.layouts[bufferIdx].stepRate     = binding.getDivisor();
                }
                desc.layouts[bufferIdx].stride = mCurrentArrayBufferStrides[v];

                if (mCurrentArrayBuffers[v])
                {
                    cmdEncoder->setVertexBuffer(mCurrentArrayBuffers[v]->getCurrentBuffer(),
                                                bufferOffset, bufferIdx);
                }
                else
                {
                    // No buffer specified, use the client memory directly as inline constant data
                    ASSERT(mCurrentArrayInlineDataSizes[v] <= mtl::kInlineConstDataMaxSize);
                    cmdEncoder->setVertexBytes(mCurrentArrayInlineDataPointers[v],
                                               mCurrentArrayInlineDataSizes[v], bufferIdx);
                }
            }
        }  // for (v)
    }

    *vertexDescChanged = dirty;

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::updateClientAttribs(const gl::Context *context,
                                                  GLint firstVertex,
                                                  GLsizei vertexOrIndexCount,
                                                  GLsizei instanceCount,
                                                  gl::DrawElementsType indexTypeOrInvalid,
                                                  const void *indices)
{
    ContextMtl *contextMtl                  = mtl::GetImpl(context);
    const gl::AttributesMask &clientAttribs = context->getStateCache().getActiveClientAttribsMask();

    ASSERT(clientAttribs.any());

    GLint startVertex;
    size_t vertexCount;
    ANGLE_TRY(GetVertexRangeInfo(context, firstVertex, vertexOrIndexCount, indexTypeOrInvalid,
                                 indices, 0, &startVertex, &vertexCount));

    mDynamicVertexData.releaseInFlightBuffers(contextMtl);

    const std::vector<gl::VertexAttribute> &attribs = mState.getVertexAttributes();
    const std::vector<gl::VertexBinding> &bindings  = mState.getVertexBindings();

    for (size_t attribIndex : clientAttribs)
    {
        const gl::VertexAttribute &attrib = attribs[attribIndex];
        const gl::VertexBinding &binding  = bindings[attrib.bindingIndex];
        ASSERT(attrib.enabled && binding.getBuffer().get() == nullptr);

        // Source client memory pointer
        const uint8_t *src = static_cast<const uint8_t *>(attrib.pointer);
        ASSERT(src);

        GLint startElement;
        size_t elementCount;
        if (binding.getDivisor() == 0)
        {
            // Per vertex attribute
            startElement = startVertex;
            elementCount = vertexCount;
        }
        else
        {
            // Per instance attribute
            startElement = 0;
            elementCount = UnsignedCeilDivide(instanceCount, binding.getDivisor());
        }
        size_t bytesIntendedToUse = (startElement + elementCount) * binding.getStride();

        const mtl::VertexFormat &format = contextMtl->getVertexFormat(attrib.format->id, false);
        bool needStreaming              = format.actualFormatId != format.intendedFormatId ||
                             (binding.getStride() % mtl::kVertexAttribBufferStrideAlignment) != 0 ||
                             (binding.getStride() < format.actualAngleFormat().pixelBytes) ||
                             bytesIntendedToUse > mtl::kInlineConstDataMaxSize;

        if (!needStreaming)
        {
            // Data will be uploaded directly as inline constant data
            mCurrentArrayBuffers[attribIndex]            = nullptr;
            mCurrentArrayInlineDataPointers[attribIndex] = src;
            mCurrentArrayInlineDataSizes[attribIndex]    = bytesIntendedToUse;
            mCurrentArrayBufferOffsets[attribIndex]      = 0;
            mCurrentArrayBufferFormats[attribIndex]      = &format;
            mCurrentArrayBufferStrides[attribIndex]      = binding.getStride();
        }
        else
        {
            GLuint convertedStride;
            // Need to stream the client vertex data to a buffer.
            const mtl::VertexFormat &streamFormat =
                GetVertexConversionFormat(contextMtl, attrib.format->id, &convertedStride);

            // Allocate space for startElement + elementCount so indexing will work.  If we don't
            // start at zero all the indices will be off.
            // Only elementCount vertices will be used by the upcoming draw so that is all we copy.
            size_t bytesToAllocate = (startElement + elementCount) * convertedStride;
            src += startElement * binding.getStride();
            size_t destOffset = startElement * convertedStride;

            mCurrentArrayBufferFormats[attribIndex] = &streamFormat;
            mCurrentArrayBufferStrides[attribIndex] = convertedStride;

            if (bytesToAllocate <= mtl::kInlineConstDataMaxSize)
            {
                // If the data is small enough, use host memory instead of creating GPU buffer. To
                // avoid synchronizing access to GPU buffer that is still in use.
                angle::MemoryBuffer &convertedClientArray =
                    mConvertedClientSmallArrays[attribIndex];
                if (bytesToAllocate > convertedClientArray.size())
                {
                    ANGLE_CHECK_GL_ALLOC(contextMtl, convertedClientArray.resize(bytesToAllocate));
                }

                ASSERT(streamFormat.vertexLoadFunction);
                streamFormat.vertexLoadFunction(src, binding.getStride(), elementCount,
                                                convertedClientArray.data() + destOffset);

                mCurrentArrayBuffers[attribIndex]            = nullptr;
                mCurrentArrayInlineDataPointers[attribIndex] = convertedClientArray.data();
                mCurrentArrayInlineDataSizes[attribIndex]    = bytesToAllocate;
                mCurrentArrayBufferOffsets[attribIndex]      = 0;
            }
            else
            {
                // Stream the client data to a GPU buffer. Synchronization might happen if buffer is
                // in use.
                ANGLE_TRY(StreamVertexData(contextMtl, &mDynamicVertexData, src, bytesToAllocate,
                                           destOffset, elementCount, binding.getStride(),
                                           streamFormat.vertexLoadFunction,
                                           &mConvertedArrayBufferHolders[attribIndex],
                                           &mCurrentArrayBufferOffsets[attribIndex]));

                mCurrentArrayBuffers[attribIndex] = &mConvertedArrayBufferHolders[attribIndex];
            }
        }  // if (needStreaming)
    }

    mVertexArrayDirty = true;

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::syncDirtyAttrib(const gl::Context *glContext,
                                              const gl::VertexAttribute &attrib,
                                              const gl::VertexBinding &binding,
                                              size_t attribIndex)
{
    ContextMtl *contextMtl = mtl::GetImpl(glContext);
    ASSERT(mtl::kMaxVertexAttribs > attribIndex);

    if (attrib.enabled)
    {
        gl::Buffer *bufferGL            = binding.getBuffer().get();
        const mtl::VertexFormat &format = contextMtl->getVertexFormat(attrib.format->id, false);

        if (bufferGL)
        {
            BufferMtl *bufferMtl = mtl::GetImpl(bufferGL);
            bool needConversion =
                format.actualFormatId != format.intendedFormatId ||
                (binding.getOffset() % format.actualAngleFormat().pixelBytes) != 0 ||
                (binding.getStride() < format.actualAngleFormat().pixelBytes) ||
                (binding.getStride() % mtl::kVertexAttribBufferStrideAlignment) != 0;

            if (needConversion)
            {
                ANGLE_TRY(convertVertexBuffer(glContext, bufferMtl, binding, attribIndex, format));
            }
            else
            {
                mCurrentArrayBuffers[attribIndex]       = bufferMtl;
                mCurrentArrayBufferOffsets[attribIndex] = binding.getOffset();
                mCurrentArrayBufferStrides[attribIndex] = binding.getStride();

                mCurrentArrayBufferFormats[attribIndex] = &format;
            }
        }
        else
        {
            // ContextMtl must feed the client data using updateClientAttribs()
        }
    }
    else
    {
        const gl::State &glState = glContext->getState();
        const gl::VertexAttribCurrentValueData &defaultValue =
            glState.getVertexAttribCurrentValues()[attribIndex];

        // Tell ContextMtl to update default attribute value
        contextMtl->invalidateDefaultAttribute(attribIndex);

        mCurrentArrayBuffers[attribIndex]       = nullptr;
        mCurrentArrayBufferOffsets[attribIndex] = 0;
        mCurrentArrayBufferStrides[attribIndex] = 0;

        const mtl::VertexFormat *vertexFormat = nullptr;
        switch (defaultValue.Type)
        {
            case gl::VertexAttribType::Int:
                vertexFormat =
                    &contextMtl->getVertexFormat(angle::FormatID::R32G32B32A32_SINT, false);
                break;
            case gl::VertexAttribType::UnsignedInt:
                vertexFormat =
                    &contextMtl->getVertexFormat(angle::FormatID::R32G32B32A32_UINT, false);
                break;
            case gl::VertexAttribType::Float:
                vertexFormat =
                    &contextMtl->getVertexFormat(angle::FormatID::R32G32B32A32_FLOAT, false);
                break;
            default:
                UNREACHABLE();
        }
        mCurrentArrayBufferFormats[attribIndex] = vertexFormat;
    }

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::getIndexBuffer(const gl::Context *context,
                                             gl::DrawElementsType type,
                                             size_t count,
                                             const void *indices,
                                             mtl::BufferRef *idxBufferOut,
                                             size_t *idxBufferOffsetOut,
                                             gl::DrawElementsType *indexTypeOut)
{
    const gl::Buffer *glElementArrayBuffer = getState().getElementArrayBuffer();

    size_t convertedOffset = reinterpret_cast<size_t>(indices);
    if (!glElementArrayBuffer)
    {
        ANGLE_TRY(streamIndexBufferFromClient(context, type, count, indices, idxBufferOut,
                                              idxBufferOffsetOut));
    }
    else
    {
        bool needConversion = type == gl::DrawElementsType::UnsignedByte ||
                              (convertedOffset % mtl::kIndexBufferOffsetAlignment) != 0;
        if (needConversion)
        {
            ANGLE_TRY(convertIndexBuffer(context, type, convertedOffset, idxBufferOut,
                                         idxBufferOffsetOut));
        }
        else
        {
            // No conversion needed:
            BufferMtl *bufferMtl = mtl::GetImpl(glElementArrayBuffer);
            *idxBufferOut        = bufferMtl->getCurrentBuffer();
            *idxBufferOffsetOut  = convertedOffset;
        }
    }

    *indexTypeOut = type;
    if (type == gl::DrawElementsType::UnsignedByte)
    {
        // This buffer is already converted to ushort indices above
        *indexTypeOut = gl::DrawElementsType::UnsignedShort;
    }

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::convertIndexBuffer(const gl::Context *glContext,
                                                 gl::DrawElementsType indexType,
                                                 size_t offset,
                                                 mtl::BufferRef *idxBufferOut,
                                                 size_t *idxBufferOffsetOut)
{
    ASSERT((offset % mtl::kIndexBufferOffsetAlignment) != 0 ||
           indexType == gl::DrawElementsType::UnsignedByte);

    BufferMtl *idxBuffer = mtl::GetImpl(getState().getElementArrayBuffer());

    IndexConversionBufferMtl *conversion =
        idxBuffer->getIndexConversionBuffer(mtl::GetImpl(glContext), indexType, offset);

    // Has the content of the buffer has changed since last conversion?
    if (!conversion->dirty)
    {
        // reuse the converted buffer
        *idxBufferOut       = conversion->convertedBuffer;
        *idxBufferOffsetOut = conversion->convertedOffset;
        return angle::Result::Continue;
    }

    size_t indexCount = GetIndexCount(idxBuffer, offset, indexType);

    ANGLE_TRY(
        convertIndexBufferGPU(glContext, indexType, idxBuffer, offset, indexCount, conversion));

    *idxBufferOut       = conversion->convertedBuffer;
    *idxBufferOffsetOut = conversion->convertedOffset;

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::convertIndexBufferGPU(const gl::Context *glContext,
                                                    gl::DrawElementsType indexType,
                                                    BufferMtl *idxBuffer,
                                                    size_t offset,
                                                    size_t indexCount,
                                                    IndexConversionBufferMtl *conversion)
{
    ContextMtl *contextMtl = mtl::GetImpl(glContext);
    DisplayMtl *display    = contextMtl->getDisplay();

    const size_t amount = GetIndexConvertedBufferSize(indexType, indexCount);

    // Allocate new buffer, save it in conversion struct so that we can reuse it when the content
    // of the original buffer is not dirty.
    conversion->data.releaseInFlightBuffers(contextMtl);
    ANGLE_TRY(conversion->data.allocate(contextMtl, amount, nullptr, &conversion->convertedBuffer,
                                        &conversion->convertedOffset));

    // Do the conversion on GPU.
    ANGLE_TRY(display->getUtils().convertIndexBuffer(
        contextMtl, indexType, static_cast<uint32_t>(indexCount), idxBuffer->getCurrentBuffer(),
        static_cast<uint32_t>(offset), conversion->convertedBuffer,
        static_cast<uint32_t>(conversion->convertedOffset)));

    ANGLE_TRY(conversion->data.commit(contextMtl));

    ASSERT(conversion->dirty);
    conversion->dirty = false;

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::streamIndexBufferFromClient(const gl::Context *context,
                                                          gl::DrawElementsType indexType,
                                                          size_t indexCount,
                                                          const void *sourcePointer,
                                                          mtl::BufferRef *idxBufferOut,
                                                          size_t *idxBufferOffsetOut)
{
    ASSERT(getState().getElementArrayBuffer() == nullptr);
    ContextMtl *contextMtl = mtl::GetImpl(context);

    auto srcData = static_cast<const uint8_t *>(sourcePointer);
    ANGLE_TRY(StreamIndexData(contextMtl, &mDynamicIndexData, srcData, indexType, indexCount,
                              idxBufferOut, idxBufferOffsetOut));

    return angle::Result::Continue;
}

angle::Result VertexArrayMtl::convertVertexBuffer(const gl::Context *glContext,
                                                  BufferMtl *srcBuffer,
                                                  const gl::VertexBinding &binding,
                                                  size_t attribIndex,
                                                  const mtl::VertexFormat &srcVertexFormat)
{
    const angle::Format &intendedAngleFormat = srcVertexFormat.intendedAngleFormat();

    ConversionBufferMtl *conversion = srcBuffer->getVertexConversionBuffer(
        mtl::GetImpl(glContext), intendedAngleFormat.id, binding.getStride(), binding.getOffset());

    // Has the content of the buffer has changed since last conversion?
    if (!conversion->dirty)
    {
        ContextMtl *contextMtl = mtl::GetImpl(glContext);

        // Buffer's data hasn't been changed. Re-use last converted results
        GLuint stride;
        const mtl::VertexFormat &vertexFormat =
            GetVertexConversionFormat(contextMtl, intendedAngleFormat.id, &stride);

        mConvertedArrayBufferHolders[attribIndex].set(conversion->convertedBuffer);
        mCurrentArrayBufferOffsets[attribIndex] = conversion->convertedOffset;

        mCurrentArrayBuffers[attribIndex]       = &mConvertedArrayBufferHolders[attribIndex];
        mCurrentArrayBufferFormats[attribIndex] = &vertexFormat;
        mCurrentArrayBufferStrides[attribIndex] = stride;
        return angle::Result::Continue;
    }

    // NOTE(hqle): Do the conversion on GPU.
    return convertVertexBufferCPU(glContext, srcBuffer, binding, attribIndex, srcVertexFormat,
                                  conversion);
}

angle::Result VertexArrayMtl::convertVertexBufferCPU(const gl::Context *glContext,
                                                     BufferMtl *srcBuffer,
                                                     const gl::VertexBinding &binding,
                                                     size_t attribIndex,
                                                     const mtl::VertexFormat &srcVertexFormat,
                                                     ConversionBufferMtl *conversion)
{
    ContextMtl *contextMtl = mtl::GetImpl(glContext);

    // Convert to tightly packed format
    GLuint stride;
    const mtl::VertexFormat &vertexFormat =
        GetVertexConversionFormat(contextMtl, srcVertexFormat.intendedFormatId, &stride);
    unsigned srcFormatSize = vertexFormat.intendedAngleFormat().pixelBytes;

    conversion->data.releaseInFlightBuffers(contextMtl);

    size_t numVertices = GetVertexCount(srcBuffer, binding, srcFormatSize);
    if (numVertices == 0)
    {
        // Out of bound buffer access, can return any values.
        // See KHR_robust_buffer_access_behavior
        mCurrentArrayBuffers[attribIndex]       = srcBuffer;
        mCurrentArrayBufferFormats[attribIndex] = &srcVertexFormat;
        mCurrentArrayBufferOffsets[attribIndex] = 0;
        mCurrentArrayBufferStrides[attribIndex] = 16;
        return angle::Result::Continue;
    }

    const uint8_t *srcBytes = srcBuffer->getClientShadowCopyData(contextMtl);
    ANGLE_CHECK_GL_ALLOC(contextMtl, srcBytes);

    srcBytes += binding.getOffset();

    ANGLE_TRY(StreamVertexData(contextMtl, &conversion->data, srcBytes, numVertices * stride, 0,
                               numVertices, binding.getStride(), vertexFormat.vertexLoadFunction,
                               &mConvertedArrayBufferHolders[attribIndex],
                               &mCurrentArrayBufferOffsets[attribIndex]));

    mCurrentArrayBuffers[attribIndex]       = &mConvertedArrayBufferHolders[attribIndex];
    mCurrentArrayBufferFormats[attribIndex] = &vertexFormat;
    mCurrentArrayBufferStrides[attribIndex] = stride;

    // Cache the last converted results to be re-used later if the buffer's content won't ever be
    // changed.
    conversion->convertedBuffer = mConvertedArrayBufferHolders[attribIndex].getCurrentBuffer();
    conversion->convertedOffset = mCurrentArrayBufferOffsets[attribIndex];

#ifndef NDEBUG
    ANGLE_MTL_OBJC_SCOPE
    {
        mConvertedArrayBufferHolders[attribIndex].getCurrentBuffer()->get().label =
            [NSString stringWithFormat:@"Converted from %p offset=%zu stride=%u", srcBuffer,
                                       binding.getOffset(), binding.getStride()];
    }
#endif

    ASSERT(conversion->dirty);
    conversion->dirty = false;

    return angle::Result::Continue;
}
}
