#include <string>
#include <iostream>
#include <unordered_map>
#include <map>
#include <stdlib.h>
#include <time.h>
#include <string>
#include <assert.h>

const uint itNum = 100;
const uint startingNum = 0;
const uint elementsToTest = 10000;
const uint numToAdd = 8;
const uint someNum = 9213146;
const uint numbersNum = startingNum + itNum * numToAdd;

typedef unsigned int uint;
uint *numbers;

struct Result
{
    long unsigned elementsNum;
    float time;
};

volatile int aa;
void doNotOptimize(int num)
{
    aa = num;
}

Result *data;

void loadNumbers()
{
    int fileNumbersNum;
    FILE *file = fopen("test_numbers.bin", "rb");

    fseek(file, 0L, SEEK_END);
    fileNumbersNum = ftell(file) / 4;
    fseek(file, 0L, SEEK_SET);
    assert(fileNumbersNum == numbersNum);

    numbers = (uint *)malloc(fileNumbersNum * 4);
    fread(numbers, fileNumbersNum * 4, 1, file);
    fclose(file);
}
int trueResults = 0;

template <class MapType>
void testMap(MapType map, const char *dataPath)
{
    size_t lastAdded = startingNum;
    timespec start;
    timespec end;

    for (int it = 0; it < itNum; it++)
    {
        for (int i = 0; i < startingNum; i++)
        {
            uint n = numbers[i] * someNum;
            map.insert({n, true});
        }
        for (int i = lastAdded; i < lastAdded + numToAdd; i++)
        {
            uint n = numbers[i] * someNum;
            map.insert({n, true});
        }
        lastAdded += numToAdd;

        clock_gettime(CLOCK_MONOTONIC, &start);

        /*for (int i = 0; i < elementsToTest; i++)
        {
            auto search = map.find(i);
            auto ret = search != map.end();
            trueResults += 1; //cast(typeof(trueResults))(cast(bool)ret);
            doNotOptimize(ret);
        }*/
        for (int kkk = 0; kkk < 1000; kkk++)
        for (int i = 0; i < lastAdded; i++)
        {
            auto n = numbers[i];
            n *= someNum;
            auto search = map.find(n);
            //assert(search != map.end());
            auto ret = search != map.end();
            trueResults += ret; //cast(typeof(trueResults))(cast(bool)ret);
            doNotOptimize(ret);
        }

        clock_gettime(CLOCK_MONOTONIC, &end);
        data[it].elementsNum = lastAdded;
        data[it].time = ((end.tv_nsec - start.tv_nsec) + (end.tv_sec - start.tv_sec) * 1000000000) / 1000000000.0f;
    }

    FILE *file = fopen(dataPath, "w");
    for (int i = 0; i < itNum; i++)
    {
        auto d = data[i];
        fprintf(file, "%lu %f\n", d.elementsNum, d.time);
    }
    fclose(file);
}

int main()
{
    loadNumbers();
    printf("%d\n", numbersNum);
    for (int i = 0; i < 5; i++)
    {
        // printf("%u\n", numbers[i]);
    }

    std::map<uint, bool> map = {};
    std::unordered_map<uint, bool> unordered_map = {};

    data = (Result *)malloc(itNum * sizeof(Result));

    testMap(unordered_map, "time_cpp_unordered_map.data");
    testMap(map, "time_cpp_map.data");
}

//g++-8 -std=c++14 src/test_hash_map.cpp -o output ; ./output
//gnuplot script.gnuplot ; gnuplot distribution.gnuplot