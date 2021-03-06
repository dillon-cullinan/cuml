/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "umapparams.h"
#include "knn/knn.h"

#pragma once

namespace ML {


    class UMAP_API {

        UMAPParams *params;
        kNN *knn;

        public:

        UMAP_API(UMAPParams *params);
        ~UMAP_API();

            /**
             * Fits a UMAP model
             * @param X
             *        pointer to an array in row-major format (note: this will be col-major soon)
             * @param n
             *        n_samples in X
             * @param d
             *        d_features in X
             * @param embeddings
             *        an array to return the output embeddings of size (n_samples, n_components)
             */
            void fit(float *X, int n, int d, float *embeddings);

            /**
             * Project a set of X vectors into the embedding space.
             * @param X
             *        pointer to an array in row-major format (note: this will be col-major soon)
             * @param n
             *        n_samples in X
             * @param d
             *        d_features in X
             * @param embedding
             *        pointer to embedding array of size (embedding_n, n_components) that has been created with fit()
             * @param embedding_n
             *        n_samples in embedding array
             * @param out
             *        pointer to array for storing output embeddings (n, n_components)
             */
            void transform(float *X, int n, int d,
                    float *embedding, int embedding_n,
                    float *out);

            /**
             * Get the UMAPParams instance
             */
            UMAPParams* get_params();
    };
}


