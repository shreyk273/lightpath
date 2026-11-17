// Stand-in for Sunshine's logging so mutter_rd.cpp builds on its own.
#pragma once
#include <iostream>
#include <string_view>
#define BOOST_LOG(level) std::clog << "\n[" #level "] "
