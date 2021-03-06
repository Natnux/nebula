kernel void voxelize(
    global float4 * point_data,
    global int * point_data_offset,
    global int * point_data_count,
    global float * brick_extent,
    global float * pool_cluster,
    global float * min_check,
    global float * sum_check,
    global float * variance_check,
    local float * addition_array,
    uint brick_outer_dimension,
    float search_radius,
    float data_point_radius

)
{
    // Each Work Group is one brick. Each Work Item is one interpolation point in the brick.
    int4 id_loc = (int4)(get_local_id(0), get_local_id(1), get_local_id(2), 0);

    int id_output = id_loc.x + id_loc.y * brick_outer_dimension + id_loc.z * brick_outer_dimension * brick_outer_dimension;

    int id_wg = get_global_id(2) / brick_outer_dimension;

    // Position of point
    float4 xyzw;
    float sample_interdistance = (brick_extent[id_wg * 6 + 1] - brick_extent[id_wg * 6 + 0]) / ((float)brick_outer_dimension - 1.0f);
    xyzw.x = brick_extent[id_wg * 6 + 0] + (float)id_loc.x * sample_interdistance;
    xyzw.y = brick_extent[id_wg * 6 + 2] + (float)id_loc.y * sample_interdistance;
    xyzw.z = brick_extent[id_wg * 6 + 4] + (float)id_loc.z * sample_interdistance;
    xyzw.w = 0.0f;

    // Interpolate around positions using invrese distance weighting
    float4 point;
    float sum_intensity = 0.0f;
    float sum_distance = 0.0f;
    float dst;

    if (1) // Inverse distance weighting (IDW) interpolation
    {
        for (int i = 0; i < point_data_count[id_wg]; i++)
        {
            point = point_data[point_data_offset[id_wg] + i];
            dst = fast_distance(xyzw.xyz, point.xyz);

            if (dst <= 0.0f)
            {
                sum_intensity = point.w;
                sum_distance = 1.0f;
                break;
            }

            if (dst <= search_radius)
            {
                sum_intensity += native_divide(point.w, dst);
                sum_distance += native_divide(1.0f, dst);
            }
        }

        if (sum_distance > 0)
        {
            xyzw.w = sum_intensity / sum_distance;
        }
    }
    if (0) // IDW interpolation combined with approximate volume fill ratio linear scaling
    {
        float fill_ratio = min(1.0f, (float) point_data_count[id_wg] *  (4.0f*M_PI_F/3.0f) * pow(0.5f*data_point_radius,3.0f) / pow(sample_interdistance*7,3.0f));


        for (int i = 0; i < point_data_count[id_wg]; i++)
        {
            point = point_data[point_data_offset[id_wg] + i];
            dst = fast_distance(xyzw.xyz, point.xyz);

            if (dst <= 0.0f)
            {
                sum_intensity = point.w;
                sum_distance = 1.0f;
                break;
            }

            if (dst <= search_radius)
            {
                sum_intensity += native_divide(point.w, dst);
                sum_distance += native_divide(1.0f, dst);
            }
        }

        if (sum_distance > 0)
        {
            xyzw.w = sum_intensity * fill_ratio / sum_distance;
        }
    }

    // Pass result to output array
    pool_cluster[id_wg * brick_outer_dimension * brick_outer_dimension * brick_outer_dimension + id_output] = xyzw.w;

    // Parallel reduction that instead of summing finds the minimum value
    addition_array[id_output] = xyzw.w;

    barrier(CLK_LOCAL_MEM_FENCE);

    for (unsigned int i = 256; i > 0; i >>= 1)
    {
        if (id_output < i)
        {
            if (addition_array[id_output] < addition_array[i + id_output])
            {
                addition_array[id_output] = addition_array[i + id_output];
            }
        }

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (id_output == 0)
    {
        min_check[id_wg] = addition_array[0];
    }

    // Parallel reduction to find the sum
    addition_array[id_output] = xyzw.w;

    barrier(CLK_LOCAL_MEM_FENCE);

    for (unsigned int i = 256; i > 0; i >>= 1)
    {
        if (id_output < i)
        {
            if (addition_array[id_output] < addition_array[i + id_output])
            {
                addition_array[id_output] = addition_array[i + id_output];
            }

            addition_array[id_output] += addition_array[i + id_output];
        }

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (id_output == 0)
    {
        sum_check[id_wg] = addition_array[0];
    }



    // Parallel reduction to find the variance
    float average = addition_array[0] / (float)(brick_outer_dimension * brick_outer_dimension * brick_outer_dimension);

    barrier(CLK_LOCAL_MEM_FENCE);
    addition_array[id_output] = (xyzw.w - average) * (xyzw.w - average);

    barrier(CLK_LOCAL_MEM_FENCE);

    for (unsigned int i = 256; i > 0; i >>= 1)
    {
        if (id_output < i)
        {
            addition_array[id_output] += addition_array[i + id_output];
        }

        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (id_output == 0)
    {
        variance_check[id_wg] = addition_array[0] / (float)(brick_outer_dimension * brick_outer_dimension * brick_outer_dimension);
    }
}

uint target_index(int4 target_dimension, int4 id_loc , uint brick_outer_dimension, uint brick_count)
{
    int4 target_brick_dimension = target_dimension / (int4)(brick_outer_dimension);

    int4 brick_offset;
    brick_offset.z = brick_count / (target_brick_dimension.x * target_brick_dimension.y);
    brick_offset.y = (brick_count % (target_brick_dimension.x * target_brick_dimension.y)) / target_brick_dimension.x;
    brick_offset.x = (brick_count % (target_brick_dimension.x * target_brick_dimension.y)) % target_brick_dimension.x;

    int4 index3d = brick_offset * (int4)(brick_outer_dimension) + id_loc;

    return index3d.x + index3d.y * target_dimension.x + index3d.z * target_dimension.x * target_dimension.y;
}

kernel void fill(
    global float * pool_cluster,
    global float * pool,
    int4 pool_dimension,
    uint brick_outer_dimension,
    uint brick_count
)
{
    // Move relevant (nonzero) data from temporary storage to permanent storage

    int4 id_loc = (int4)(get_local_id(0), get_local_id(1), get_local_id(2), 0);

    int id_wg = get_global_id(2) / brick_outer_dimension;

    int id_output = id_loc.x + id_loc.y * brick_outer_dimension + id_loc.z * brick_outer_dimension * brick_outer_dimension;


    uint i = target_index(pool_dimension, id_loc , brick_outer_dimension, brick_count);
    uint j = id_wg * brick_outer_dimension * brick_outer_dimension * brick_outer_dimension + id_output;

    pool[i] = pool_cluster[j];
}
