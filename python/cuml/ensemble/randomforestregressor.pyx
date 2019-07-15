#
# Copyright (c) 2019, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# cython: profile=False
# distutils: language = c++
# cython: embedsignature = True
# cython: language_level = 3

import ctypes
import math
import numpy as np
import warnings
import pdb

from numba import cuda

from libcpp cimport bool
from libc.stdint cimport uintptr_t
from libc.stdlib cimport calloc, malloc, free

from cuml.common.base import Base
from cuml.common.handle cimport cumlHandle
from cuml.utils import get_cudf_column_ptr, get_dev_array_ptr, \
    input_to_dev_array, zeros
cimport cuml.common.handle
cimport cuml.common.cuda

cdef extern from "randomforest/randomforest.hpp" namespace "ML":
    cdef enum CRITERION:
        GINI,
        ENTROPY,
        MSE,
        MAE,
        CRITERION_END

cdef extern from "decisiontree/decisiontree.hpp" namespace "ML::DecisionTree":
    cdef struct DecisionTreeParams:
        int max_depth
        int max_leaves
        float max_features
        int n_bins
        int split_algo
        int min_rows_per_node
        bool bootstrap_features
        bool quantile_per_tree
        CRITERION split_criterion

cdef extern from "randomforest/randomforest.hpp" namespace "ML":

    cdef enum RF_type:
        CLASSIFICATION,
        REGRESSION

    cdef struct RF_metrics:
        RF_type rf_type
        float accuracy
        double mean_abs_error
        double mean_squared_error
        double median_abs_error

    cdef struct RF_params:
        int n_trees
        bool bootstrap
        float rows_sample
        pass

    cdef cppclass RandomForestMetaData[T, L]:
        void* trees
        RF_params rf_params

    # Random Forest Classifier
    cdef void fit(cumlHandle & handle,
                  RandomForestMetaData[float, float]*,
                  float *,
                  int,
                  int,
                  float *,
                  RF_params) except +

    cdef void fit(cumlHandle & handle,
                  RandomForestMetaData[double, double]*,
                  double *,
                  int,
                  int,
                  double *,
                  RF_params) except +

    cdef void predict(cumlHandle& handle,
                      RandomForestMetaData[float, float] *,
                      float *,
                      int,
                      int,
                      float *,
                      bool) except +

    cdef void predict(cumlHandle& handle,
                      RandomForestMetaData[double, double]*,
                      double *,
                      int,
                      int,
                      double *,
                      bool) except +

    cdef RF_metrics score(cumlHandle& handle,
                          RandomForestMetaData[float, float]*,
                          float *, float *,
                          int, int, float *, bool) except +

    cdef RF_metrics score(cumlHandle& handle,
                          RandomForestMetaData[double, double]*,
                          double *, double *,
                          int, int, double *, bool) except +

    cdef void print_rf_summary(RandomForestMetaData[float, float]*) except +
    cdef void print_rf_summary(RandomForestMetaData[double, double]*) except +

    cdef void print_rf_detailed(RandomForestMetaData[float, float]*) except +
    cdef void print_rf_detailed(RandomForestMetaData[double, double]*) except +

    cdef RF_params set_rf_class_obj(int, int, float,
                                    int, int, int,
                                    bool, bool, int, float, CRITERION,
                                    bool) except +


class RandomForestRegressor(Base):
    """
    Implements a Random Forest classifier model which fits multiple decision
    tree classifiers in an ensemble.

    Note that the underlying algorithm for tree node splits differs from that
    used in scikit-learn. By default, the cuML Random Forest uses a
    histogram-based algorithms to determine splits, rather than an exact
    count. You can tune the size of the histograms with the n_bins parameter.

    **Known Limitations**: This is an initial preview release of the cuML
    Random Forest code. It contains a number of known
    limitations:

       * Only classification is supported. Regression support is planned for
         the next release.

       * The implementation relies on limited CUDA shared memory for scratch
         space, so models with a very large number of features or bins will
         generate a memory limit exception. This limitation will be lifted in
         the next release.

       * Inference/prediction takes place on the CPU. A GPU-based inference
         solution is planned for a near-future release release.

       * Instances of RandomForestRegressor cannot be pickled currently.

    The code is under heavy development, so users who need these features may
    wish to pull from nightly builds of cuML. (See https://rapids.ai/start.html
    for instructions to download nightly packages via conda.)

    Examples
    ---------
    .. code-block:: python

            import numpy as np
            from cuml.ensemble import RandomForestRegressor as cuRFC

            X = np.random.normal(size=(10,4)).astype(np.float32)
            y = np.asarray([0,1]*5, dtype=np.int32)

            cuml_model = cuRFC(max_features=1.0,
                               n_bins=8,
                               n_estimators=40)
            cuml_model.fit(X,y)
            cuml_predict = cuml_model.predict(X)

            print("Predicted labels : ", cuml_predict)

    Output:

    .. code-block:: none

            Predicted labels :  [0 1 0 1 0 1 0 1 0 1]

    Parameters
    -----------
    n_estimators : int (default = 10)
                   number of trees in the forest.
    handle : cuml.Handle
             If it is None, a new one is created just for this class.
    split_criterion: The criterion used to split nodes.
                     0 for GINI, 1 for ENTROPY, 4 for CRITERION_END.
                     2 and 3 not valid for classification
                     (default = 0)
    split_algo : 0 for HIST and 1 for GLOBAL_QUANTILE
                 (default = 0)
                 the algorithm to determine how nodes are split in the tree.
    split_criterion: The criterion used to split nodes.
                     0 for GINI, 1 for ENTROPY, 4 for CRITERION_END.
                     2 and 3 not valid for classification
                     (default = 0)
    bootstrap : boolean (default = True)
                Control bootstrapping.
                If set, each tree in the forest is built
                on a bootstrapped sample with replacement.
                If false, sampling without replacement is done.
    bootstrap_features : boolean (default = False)
                         Control bootstrapping for features.
                         If features are drawn with or without replacement
    rows_sample : float (default = 1.0)
                  Ratio of dataset rows used while fitting each tree.
    max_depth : int (default = -1)
                Maximum tree depth. Unlimited (i.e, until leaves are pure),
                if -1.
    max_leaves : int (default = -1)
                 Maximum leaf nodes per tree. Soft constraint. Unlimited,
                 if -1.
    max_features : float (default = 1.0)
                   Ratio of number of features (columns) to consider
                   per node split.
    n_bins :  int (default = 8)
              Number of bins used by the split algorithm.
    min_rows_per_node : int (default = 2)
                        The minimum number of samples (rows) needed
                        to split a node.
    quantile_per_tree : boolean (default = False)
                        Whether quantile is computed for individal trees in RF.
                        Only relevant for GLOBAL_QUANTILE split_algo.

    """

    variables = ['n_estimators', 'max_depth', 'handle',
                 'max_features', 'n_bins',
                 'split_algo', 'split_criterion', 'min_rows_per_node',
                 'bootstrap', 'bootstrap_features',
                 'verbose', 'rows_sample',
                 'max_leaves', 'quantile_per_tree',
                 'accuracy_metric']

    def __init__(self, n_estimators=10, max_depth=-1, handle=None,
                 max_features=None, n_bins=8,
                 split_algo=1, split_criterion=2,
                 bootstrap=True, bootstrap_features=False,
                 verbose=False, min_rows_per_node=2,
                 rows_sample=1.0, max_leaves=-1,
                 accuracy_metric='mse', min_samples_leaf=None,
                 min_weight_fraction_leaf=None, n_jobs=None,
                 max_leaf_nodes=None, min_impurity_decrease=None,
                 min_impurity_split=None, oob_score=None,
                 random_state=None, warm_start=None, class_weight=None,
                 quantile_per_tree=False, criterion=None):

        sklearn_params = {"criterion": criterion,
                          "min_samples_leaf": min_samples_leaf,
                          "min_weight_fraction_leaf": min_weight_fraction_leaf,
                          "max_leaf_nodes": max_leaf_nodes,
                          "min_impurity_decrease": min_impurity_decrease,
                          "min_impurity_split": min_impurity_split,
                          "oob_score": oob_score, "n_jobs": n_jobs,
                          "random_state": random_state,
                          "warm_start": warm_start,
                          "class_weight": class_weight}

        for key, vals in sklearn_params.items():
            if vals is not None:
                raise TypeError(" The sklearn variable ", key,
                                " is not supported in cuML,"
                                " please read the cuML documentation for"
                                " more information")
        super(RandomForestRegressor, self).__init__(handle, verbose)

        self.split_algo = split_algo
        self.criterion = split_criterion
        self.split_criterion = split_criterion
        self.min_rows_per_node = min_rows_per_node
        self.bootstrap_features = bootstrap_features
        self.rows_sample = rows_sample
        self.max_leaves = max_leaves
        self.n_estimators = n_estimators
        self.max_depth = max_depth
        self.max_features = max_features
        self.bootstrap = bootstrap
        self.verbose = verbose
        self.n_bins = n_bins
        self.n_cols = None
        self.accuracy_metric = accuracy_metric
        self.quantile_per_tree = quantile_per_tree

        cdef RandomForestMetaData[float, float] *rf_forest = \
            new RandomForestMetaData[float, float]()
        self.rf_forest = <size_t> rf_forest
        cdef RandomForestMetaData[double, double] *rf_forest64 = \
            new RandomForestMetaData[double, double]()
        self.rf_forest64 = <size_t> rf_forest64
    """
    TODO:
        Add the preprocess and postprocess functions
        in the cython code to normalize the labels
    """
    def __getstate__(self):
        state = self.__dict__.copy()
        del state['handle']

        cdef size_t params_t = <size_t> self.rf_forest
        cdef  RandomForestMetaData[float, float] *rf_forest = \
            <RandomForestMetaData[float, float]*>params_t

        cdef size_t params_t64 = <size_t> self.rf_forest64
        cdef  RandomForestMetaData[double, double] *rf_forest64 = \
            <RandomForestMetaData[double, double]*>params_t64

        state['verbose'] = self.verbose
        # state["trees"] = <void *> rf_forest.trees

        if self.dtype == np.float32:
            print(" dtype is float32")
            state["rf_params"] = rf_forest.rf_params
            del state["rf_forest"]
        else:
            print(" dtype is float64")
            state["rf_params64"] = rf_forest64.rf_params
            del state["rf_forest64"]

        return state

    def __del__(self):
        cdef RandomForestMetaData[float, float]* rf_forest = \
            <RandomForestMetaData[float, float]*><size_t> self.rf_forest
        cdef RandomForestMetaData[double, double]* rf_forest64 = \
            <RandomForestMetaData[double, double]*><size_t> self.rf_forest64
        free(rf_forest)
        free(rf_forest64)

    def __setstate__(self, state):
        super(RandomForestRegressor, self).__init__(handle=None,
                                                    verbose=state['verbose'])
        cdef  RandomForestMetaData[float, float] *rf_forest = \
            new RandomForestMetaData[float, float]()

        # rf_forest.trees = state["trees"]
        cdef  RandomForestMetaData[double, double] *rf_forest64 = \
            new RandomForestMetaData[double, double]()

        # rf_forest.trees = state["trees"]
        if self.dtype == np.float32:
            print(" dtype is float32 in set state")
            rf_forest.rf_params = state["rf_params"]
            state["rf_forest"] = <size_t>rf_forest
        else:
            print(" dtype is float64 in set state")
            rf_forest64.rf_params = state["rf_params64"]
            state["rf_forest64"] = <size_t>rf_forest64

        self.__dict__.update(state)

    def _get_type(self):
        if self.criterion == 0:
            return GINI
        elif self.criterion == 1:
            return ENTROPY
        elif self.criterion == 2:
            return MSE
        elif self.criterion == 3:
            return MAE
        else:
            return CRITERION_END

    def _get_max_feat_val(self):
        if type(self.max_features) == int:
            max_feature_val = self.max_features/self.n_cols
        elif type(self.max_features) == float:
            max_feature_val = self.max_features
        elif self.max_features == 'sqrt':
            max_feature_val = 1/np.sqrt(self.n_cols)
        elif self.max_features == 'log2':
            max_feature_val = math.log2(self.n_cols)/self.n_cols
        else:
            max_feature_val = 1.0
        return max_feature_val

    def fit(self, X, y):
        """
        Perform Random Forest Classification on the input data

        Parameters
        ----------
        X : array-like (device or host) shape = (n_samples, n_features)
            Dense matrix (floats or doubles) of shape (n_samples, n_features).
            Acceptable formats: cuDF DataFrame, NumPy ndarray, Numba device
            ndarray, cuda array interface compliant array like CuPy
        y : array-like (device or host) shape = (n_samples, 1)
            Dense vector (int32) of shape (n_samples, 1).
            Acceptable formats: NumPy ndarray, Numba device
            ndarray, cuda array interface compliant array like CuPy
            These labels should be contiguous integers from 0 to n_classes.
        """
        cdef uintptr_t X_ptr, y_ptr
        cdef RandomForestMetaData[float, float] *rf_forest = \
            <RandomForestMetaData[float, float]*><size_t> self.rf_forest
        cdef RandomForestMetaData[double, double] *rf_forest64 = \
            <RandomForestMetaData[double, double]*><size_t> self.rf_forest64

        y_m, y_ptr, _, _, y_dtype = input_to_dev_array(y)

        X_m, X_ptr, n_rows, self.n_cols, self.dtype = \
            input_to_dev_array(X, order='F')

        cdef cumlHandle* handle_ =\
            <cumlHandle*><size_t>self.handle.getHandle()

        max_feature_val = self._get_max_feat_val()
        if type(self.min_rows_per_node) == float:
            self.min_rows_per_node = math.ceil(self.min_rows_per_node*n_rows)

        self.split_criterion = self._get_type()

        rf_params = set_rf_class_obj(<int> self.max_depth,
                                     <int> self.max_leaves,
                                     <float> max_feature_val,
                                     <int> self.n_bins,
                                     <int> self.split_algo,
                                     <int> self.min_rows_per_node,
                                     <bool> self.bootstrap_features,
                                     <bool> self.bootstrap,
                                     <int> self.n_estimators,
                                     <int> self.rows_sample,
                                     <CRITERION> self.split_criterion,
                                     <bool> self.quantile_per_tree)
        if self.dtype == np.float64:
            rf_params64 = rf_params

        if self.dtype == np.float32:
            fit(handle_[0],
                rf_forest,
                <float*> X_ptr,
                <int> n_rows,
                <int> self.n_cols,
                <float*> y_ptr,
                rf_params)

        else:
            fit(handle_[0],
                rf_forest64,
                <double*> X_ptr,
                <int> n_rows,
                <int> self.n_cols,
                <double*> y_ptr,
                rf_params64)
        # make sure that the `fit` is complete before the following delete
        # call happens
        self.handle.sync()
        del(X_m)
        del(y_m)
        return self

    def predict(self, X):

        cdef uintptr_t X_ptr
        # row major format
        X_m, X_ptr, n_rows, n_cols, _ = \
            input_to_dev_array(X, order='C')
        if n_cols != self.n_cols:
            raise ValueError("The number of columns/features in the training"
                             " and test data should be the same ")
        if X.dtype != self.dtype:
            raise ValueError("The datatype of the training data is different"
                             " from the datatype of the testing data")

        preds = np.zeros(n_rows, dtype=self.dtype)
        cdef uintptr_t preds_ptr
        preds_m, preds_ptr, _, _, _ = \
            input_to_dev_array(preds)
        cdef cumlHandle* handle_ =\
            <cumlHandle*><size_t>self.handle.getHandle()

        cdef RandomForestMetaData[float, float] *rf_forest = \
            <RandomForestMetaData[float, float]*><size_t> self.rf_forest

        cdef RandomForestMetaData[double, double] *rf_forest64 = \
            <RandomForestMetaData[double, double]*><size_t> self.rf_forest64
        if self.dtype == np.float32:
            predict(handle_[0],
                    rf_forest,
                    <float*> X_ptr,
                    <int> n_rows,
                    <int> n_cols,
                    <float*> preds_ptr,
                    <bool> self.verbose)

        elif self.dtype == np.float64:
            predict(handle_[0],
                    rf_forest64,
                    <double*> X_ptr,
                    <int> n_rows,
                    <int> n_cols,
                    <double*> preds_ptr,
                    <bool> self.verbose)
        else:
            raise TypeError("supports only float32 and float64 input,"
                            " but input of type '%s' passed."
                            % (str(self.dtype)))

        self.handle.sync()
        # synchronous w/o a stream
        preds = preds_m.copy_to_host()
        del(X_m)
        del(preds_m)
        return preds

    def score(self, X, y):

        cdef uintptr_t X_ptr, y_ptr
        X_m, X_ptr, n_rows, n_cols, _ = \
            input_to_dev_array(X, order='C')
        y_m, y_ptr, _, _, _ = input_to_dev_array(y)

        if n_cols != self.n_cols:
            raise ValueError("The number of columns/features in the training"
                             " and test data should be the same ")

        if X.dtype != self.dtype:
            raise ValueError("The datatype of the training data is different"
                             " from the datatype of the testing data")

        preds = np.zeros(n_rows,
                         dtype=self.dtype)
        cdef uintptr_t preds_ptr
        preds_m, preds_ptr, _, _, _ = \
            input_to_dev_array(preds)

        cdef cumlHandle* handle_ =\
            <cumlHandle*><size_t>self.handle.getHandle()

        cdef RandomForestMetaData[float, float] *rf_forest = \
            <RandomForestMetaData[float, float]*><size_t> self.rf_forest

        cdef RandomForestMetaData[double, double] *rf_forest64 = \
            <RandomForestMetaData[double, double]*><size_t> self.rf_forest64

        if self.dtype == np.float32:
            self.temp_stats = score(handle_[0],
                                    rf_forest,
                                    <float*> X_ptr,
                                    <float*> y_ptr,
                                    <int> n_rows,
                                    <int> n_cols,
                                    <float*> preds_ptr,
                                    <bool> self.verbose)

        elif self.dtype == np.float64:
            self.temp_stats = score(handle_[0],
                                    rf_forest64,
                                    <double*> X_ptr,
                                    <double*> y_ptr,
                                    <int> n_rows,
                                    <int> n_cols,
                                    <double*> preds_ptr,
                                    <bool> self.verbose)

        if self.accuracy_metric == 'median_ae':
            stats = self.temp_stats['median_abs_error']
        if self.accuracy_metric == 'mean_ae':
            stats = self.temp_stats['mean_abs_error']
        else:
            stats = self.temp_stats['mean_squared_error']

        self.handle.sync()
        del(X_m)
        del(y_m)
        del(preds_m)
        return stats

    def get_params(self, deep=True):
        """
        Returns the value of all parameters
        required to configure this estimator as a dictionary.
        Parameters
        -----------
        deep : boolean (default = True)
        """

        params = dict()
        for key in RandomForestRegressor.variables:
            var_value = getattr(self, key, None)
            params[key] = var_value
        return params

    def set_params(self, **params):
        """
        Sets the value of parameters required to
        configure this estimator, it functions similar to
        the sklearn set_params.
        Parameters
        -----------
        params : dict of new params
        """
        if not params:
            return self
        for key, value in params.items():
            if key not in RandomForestRegressor.variables:
                raise ValueError('Invalid parameter for estimator')
            else:
                setattr(self, key, value)
        self.__init__()
        return self

    def print_summary(self):

        cdef RandomForestMetaData[float, float] *rf_forest = \
            <RandomForestMetaData[float, float]*><size_t> self.rf_forest

        cdef RandomForestMetaData[double, double] *rf_forest64 = \
            <RandomForestMetaData[double, double]*><size_t> self.rf_forest64

        # Note: self.dtype is initialized in fit.
        if self.dtype == np.float64:
            print_rf_summary(rf_forest64)
        else:
            print_rf_summary(rf_forest)

    def print_detailed(self):

        cdef RandomForestMetaData[float, float] *rf_forest = \
            <RandomForestMetaData[float, float]*><size_t> self.rf_forest

        cdef RandomForestMetaData[double, double] *rf_forest64 = \
            <RandomForestMetaData[double, double]*><size_t> self.rf_forest64

        # Note: self.dtype is initialized in fit.
        if self.dtype == np.float64:
            print_rf_detailed(rf_forest64)
        else:
            print_rf_detailed(rf_forest)
